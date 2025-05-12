defmodule JumpTickets.External.NotionClientPatch do
  @moduledoc """
  Patch to fix Notion API DNS resolution issues
  """
  
  def patch_notion_client do
    # Set application environment for hackney to force IPv4
    Application.put_env(:hackney, :use_default_pool, false)
    Application.put_env(:hackney, :inet6, false)
    
    # Add additional HTTP options
    :httpc.set_options([{:ipfamily, :inet}])
    
    # Log patching information
    IO.puts("Applied DNS resolution patch for Notion API")
  end
end