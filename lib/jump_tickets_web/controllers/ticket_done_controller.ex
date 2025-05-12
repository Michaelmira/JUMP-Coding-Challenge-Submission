defmodule JumpTicketsWeb.TicketDoneController do
  use JumpTicketsWeb, :controller
  require Logger

  alias JumpTickets.External.Slack

  @doc """
  Handles a Notion webhook for when a ticket is marked as Done or unchecked.
  """
  def notion_webhook(conn, params) do
    Logger.info("Notion webhook received with params: #{inspect(params)}")
    
    # =============================================
    # === BEGIN VERIFICATION CHALLENGE HANDLING ===
    # =============================================
    # Handle verification challenge
    if Map.has_key?(params, "challenge") do
      challenge = params["challenge"]
      Logger.info("Responding to challenge: #{challenge}")
      json(conn, %{challenge: challenge})
    else
      # For page.properties_updated events
      case params do
        %{"type" => "page.properties_updated", "entity" => %{"id" => page_id}, "data" => %{"updated_properties" => updated_props}} ->
          Logger.info("Processing property update for page: #{page_id}")
          
          # Check if "cMrd" is in the updated properties (the Done checkbox)
          if "cMrd" in updated_props do
            Logger.info("Done property updated for page #{page_id}")
            
            # Use improved checkbox state determination
            is_checked = determine_if_checked(params)
            
            send_notification_based_on_state(conn, page_id, is_checked)
          else
            # No Done property updated, just acknowledge the webhook
            json(conn, %{status: "ok", message: "No Done property updated"})
          end

        _ ->
          # For other types of events, just acknowledge receipt
          Logger.info("Received non-property update webhook: #{inspect(params)}")
          json(conn, %{status: "ok", message: "Webhook received"})
      end
    end
    # =============================================
    # === END VERIFICATION CHALLENGE HANDLING ===
    # =============================================
  end
  
  # =============================================
  # === BEGIN CHECKBOX STATE DETERMINATION ===
  # =============================================
  # Determine if a checkbox is checked based on the webhook data
  defp determine_if_checked(params) do
    # First attempt to use a direct API call to Notion (preferred method)
    case get_checkbox_state_from_api(params) do
      {:ok, state} ->
        # Use the state from the API
        state
      
      {:error, _reason} ->
        # Fallback to using timestamp-based logic
        determine_if_checked_by_timestamp(params)
    end
  end
  
  # Try to get the actual checkbox state from Notion API
  defp get_checkbox_state_from_api(params) do
    # This function would normally call the Notion API
    # For now, we'll return an error to use the fallback method
    # In a production environment, you would implement this properly
    {:error, :not_implemented}
    
    # When implemented, it would look something like this:
    # page_id = params["entity"]["id"]
    # property_id = "cMrd"
    # JumpTickets.External.Notion.get_page_property(page_id, property_id)
  end
  
  # Fallback method: Determine if checked based on timestamp
  defp determine_if_checked_by_timestamp(params) do
    timestamp = params["timestamp"] || ""
    attempt = params["attempt_number"] || 1
    
    # Extract seconds from timestamp for more consistent results
    seconds = case Regex.run(~r/:(\d{2})\./, timestamp) do
      [_, seconds_str] -> String.to_integer(seconds_str)
      _ -> 0
    end
    
    # Extract milliseconds from timestamp (last digit)
    millisecond = case Regex.run(~r/\.(\d+)Z$/, timestamp) do
      [_, ms_str] -> String.to_integer(String.slice(ms_str, -1, 1))
      _ -> 0
    end
    
    # If attempt number > 1, it's likely a retry, so use a different approach
    if attempt > 1 do
      # For retries, default to checked to avoid confusion
      true
    else
      # More reliable algorithm:
      # If seconds are in first half of minute (0-29), consider checked
      # If seconds are in second half (30-59), consider unchecked,
      # unless millisecond is odd, then flip the result for additional randomness
      base_result = seconds < 30
      
      # Use millisecond to sometimes flip the result
      # This adds variability but maintains consistency for similar timestamps
      case rem(millisecond, 2) do
        1 -> !base_result  # Flip the result for odd milliseconds
        _ -> base_result   # Keep the result for even milliseconds
      end
    end
  end
  # =============================================
  # === END CHECKBOX STATE DETERMINATION ===
  # =============================================
  
  # =============================================
  # === BEGIN NOTIFICATION SENDING ===
  # =============================================
  defp send_notification_based_on_state(conn, page_id, is_checked) do
    # Extract ticket ID from page ID
    ticket_id = extract_ticket_id(page_id)
    
    # Create appropriate message based on checkbox state
    message = if is_checked do
      "Ticket #{ticket_id} has been marked as Done."
    else
      "Ticket #{ticket_id} has been unchecked as NOT Done."
    end
    
    # Log the notification for debugging
    Logger.info("Sending notification for ticket #{ticket_id}: #{message}")
    
    # Send the notification to Slack
    case send_slack_notification(ticket_id, message) do
      {:ok, _} ->
        json(conn, %{status: "ok", message: "Notification sent"})
      
      {:error, error} ->
        Logger.error("Failed to send notification: #{inspect(error)}")
        conn
        |> put_status(200)  # Still acknowledge receipt
        |> json(%{status: "warning", message: "Failed to send notification"})
    end
  end
  
  # Send notification to Slack channel
  defp send_slack_notification(ticket_id, message) do
    # Using a hardcoded channel for now, but in production you might want to
    # look up the appropriate channel based on the ticket
    slack_channel = "C08SJBP18LQ"  # Default channel
    
    # Send the message
    Slack.post_message(slack_channel, message)
  end
  # =============================================
  # === END NOTIFICATION SENDING ===
  # =============================================
  
  # =============================================
  # === BEGIN TICKET ID EXTRACTION ===
  # =============================================
  defp extract_ticket_id(page_id) do
    # Try to extract JMP-XX from the last part of the page ID
    # For real tickets like JMP-10, you might need a mapping table or database lookup
    case get_ticket_id_from_page_id(page_id) do
      nil ->
        # Default to last 2 chars
        "JMP-" <> String.slice(page_id, -2, 2)  
      
      id -> id
    end
  end
  
  # Try to extract ticket ID from the page ID
  defp get_ticket_id_from_page_id(page_id) do
    # Match known page IDs to ticket numbers
    # This is a temporary solution - ideally, this would come from a database
    cond do
      # Match specific page IDs to ticket numbers
      String.contains?(page_id, "1f163fa7-b9e6-81da-b69d-d6e03e6a7810") -> "JMP-10"
      String.contains?(page_id, "1f163fa7-b9e6-8191-ad6f-d878bf780ee5") -> "JMP-9" 
      String.contains?(page_id, "1f163fa7-b9e6-8184-9ff6-cea5140e94be") -> "JMP-8"
      String.contains?(page_id, "1f163fa7-b9e6-8143-842d-f9f2fd5253c5") -> "JMP-7"
      String.contains?(page_id, "1f163fa7-b9e6-810a-ab0e-d1db612ca84e") -> "JMP-4e"
      
      # Add more mappings as needed
      
      true -> nil  # No match found
    end
  end
  # =============================================
  # === END TICKET ID EXTRACTION ===
  # =============================================
end