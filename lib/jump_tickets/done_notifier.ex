defmodule JumpTickets.Ticket.DoneNotifier do
  @moduledoc """
  Notifies related channels and conversations when a ticket is marked as Done.
  """


  # =============================================
  # === BEGIN IMPROVED ERROR LOGGING ===
  # =============================================
  require Logger
  # =============================================
  # === END IMPROVED ERROR LOGGING ===
  # =============================================

  alias JumpTickets.External.{Slack, Intercom}

  @spec notify_ticket_done(%{
          :intercom_conversations => nil | binary(),
          :slack_channel => nil | binary() | URI.t(),
          :ticket_id => any(),
          optional(any()) => any()
        }) :: :ok
  @doc """
  Sends a done notification to the ticket's Slack channel and all linked Intercom conversations.
  """
  def notify_ticket_done(
        %{
          ticket_id: ticket_id,
          slack_channel: slack_channel,
          intercom_conversations: convs
        } = ticket
      ) do
    Logger.info("DoneNotifier triggered for ticket #{ticket_id}")  # =============================================
    Logger.info("Slack channel: #{inspect(slack_channel)}")        # === ERROR LOGGING TEMP ===
    Logger.info("Intercom conversations: #{inspect(convs)}")       # =============================================



    slack_message = "Ticket #{ticket_id} has been marked as Done."


    # =============================================
    # === BEGIN IMPROVED SLACK ERROR HANDLING ===
    # =============================================
    # Post to Slack
    slack_result = post_slack_message(slack_channel, slack_message)

    case slack_result do
      {:ok, _} -> :ok
      {:error, reason} -> Logger.error("Failed to notify Slack: #{inspect(reason)}")
    end
    # =============================================
    # === END IMPROVED SLACK ERROR HANDLING ===
    # =============================================

    # =============================================
    # === BEGIN IMPROVED INTERCOM ERROR HANDLING ===
    # =============================================
    # Post to each linked Intercom conversation
    intercom_results =
      convs
      |> parse_intercom_conversations()
      |> Enum.map(fn conversation_id ->
        intercom_message = "Ticket #{ticket_id} has been marked as Done."
        
        case Intercom.reply_to_conversation(conversation_id, intercom_message) do
          {:ok, response} -> {:ok, conversation_id, response}
          {:error, error} -> {:error, conversation_id, error}
        end
      end)

    # Log any Intercom errors
    intercom_results
    |> Enum.filter(fn 
      {:error, _, _} -> true
      _ -> false
    end)
    |> Enum.each(fn {:error, conversation_id, err} ->
      Logger.error("Failed to notify Intercom conversation #{conversation_id}: #{inspect(err)}")
    end)
    # =============================================
    # === END IMPROVED INTERCOM ERROR HANDLING ===
    # =============================================

    :ok
  end

  defp post_slack_message(nil, _), do: {:error, :no_slack_channel}
  # =============================================
  # === BEGIN IMPROVED SLACK CHANNEL VALIDATION ===
  # =============================================
  defp post_slack_message("", _), do: {:error, :empty_slack_channel}

  defp post_slack_message(slack_channel, message) when is_binary(slack_channel) do
    case extract_channel_id(slack_channel) do
      {:ok, channel_id} -> 
        Slack.post_message(channel_id, message)
      
      {:error, _} = error -> 
        error
    end
  end

  defp extract_channel_id(slack_url) do
    case URI.parse(slack_url) do
      %URI{host: "app.slack.com", path: path} ->
        parts = String.split(path, "/")
        
        case Enum.at(parts, 3) do
          nil -> {:error, :invalid_slack_channel_url}
          "" -> {:error, :invalid_slack_channel_url}
          channel_id -> {:ok, channel_id}
        end

      _ ->
        # If it's not a URL, assume it's already a channel ID
        if String.match?(slack_url, ~r/^[A-Z0-9]+$/) do
          {:ok, slack_url}
        else
          {:error, :invalid_slack_channel_format}
        end
    end
  end
  # =============================================
  # === END IMPROVED SLACK CHANNEL VALIDATION ===
  # =============================================

  defp parse_intercom_conversations(nil), do: []

  defp parse_intercom_conversations(conversations) when is_binary(conversations) do
    conversations
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&extract_conversation_id/1)
  end

  # =============================================
  # === BEGIN IMPROVED INTERCOM URL PARSING ===
  # =============================================
  defp extract_conversation_id(url) do
    # Assuming conversation URLs are in the format:
    # "https://app.intercom.io/a/apps/APP_ID/conversations/CONVERSATION_ID"
    case URI.parse(url) do
      %URI{host: "app.intercom.io", path: path} ->
        parts = String.split(path, "/")
        List.last(parts)

      _ ->
        # If it's not a URL, assume it's already a conversation ID
        url
    end
  end
  # =============================================
  # === END IMPROVED INTERCOM URL PARSING ===
  # =============================================
end
