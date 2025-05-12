defmodule JumpTicketsWeb.TicketDoneController do
  use JumpTicketsWeb, :controller
  require Logger

  @doc """
  Simplified controller that just logs and accepts any webhook from Notion
  """
  def notion_webhook(conn, params) do
    Logger.info("Notion webhook received with params: #{inspect(params)}")
    
    # Handle verification challenge
    if Map.has_key?(params, "challenge") do
      challenge = params["challenge"]
      Logger.info("Responding to challenge: #{challenge}")
      json(conn, %{challenge: challenge})
    else
      # Just log everything and return OK
      Logger.info("Webhook payload: #{inspect(params)}")
      json(conn, %{status: "ok", message: "Webhook received"})
    end
  end
end