defmodule JumpTickets.External.Notion do
  alias JumpTickets.Ticket
  alias Notionex

  def query_db() do
    db_id = Application.get_env(:jump_tickets, :notion_db_id)
    fetch_all_pages(db_id)
  end

  def fetch_all_pages(db_id, start_cursor \\ nil, accumulated_results \\ []) do

    IO.puts("Attempting to query Notion database: #{db_id}")
    IO.puts("Bearer token exists: #{!!Application.get_env(:notionex, :bearer_token)}")

    query_params = %{
      database_id: db_id,
      page_size: 100
    }

    # Add start_cursor if we're continuing pagination
    query_params =
      if start_cursor, do: Map.put(query_params, :start_cursor, start_cursor), else: query_params

    # Debug the query params
    IO.puts("Query params: #{inspect(query_params)}")

    case Notionex.API.query_database(query_params) do
      %Notionex.Object.List{results: results, has_more: true, next_cursor: next_cursor} ->
        # More pages available, recurse with the next cursor
        parsed_results = Enum.map(results, &__MODULE__.Parser.parse_ticket_page/1)
        fetch_all_pages(db_id, next_cursor, accumulated_results ++ parsed_results)

      %Notionex.Object.List{results: results, has_more: false} ->
        # Last page, return all accumulated results plus this page
        parsed_results = Enum.map(results, &__MODULE__.Parser.parse_ticket_page/1)
        {:ok, accumulated_results ++ parsed_results}

      error ->
        {:error, "Failed to query database: #{inspect(error)}"}
    end
  end

  def get_ticket_by_page_id(page_id) do
    case Notionex.API.retrieve_page(%{page_id: page_id}) do
      %Notionex.Object.Page{} = page ->
        __MODULE__.Parser.parse_ticket_page(page)

      _ ->
        {:error, "Failed to get page #{page_id}"}
    end
  end

  def create_ticket(%Ticket{} = ticket) do
    db_id = Application.get_env(:jump_tickets, :notion_db_id)

    properties = %{
      "Title" => %{
        title: [%{text: %{content: ticket.title}}]
      },
      "Intercom Conversations" => %{
        rich_text: [%{text: %{content: ticket.intercom_conversations}}]
      }
    }

    ticket =
      Notionex.API.create_page(%{
        parent: %{database_id: db_id},
        properties: properties,
        children: [
          %{
            object: "block",
            type: "paragraph",
            paragraph: %{
              rich_text: [
                %{
                  type: "text",
                  text: %{
                    content: ticket.summary
                  }
                }
              ]
            }
          }
        ]
      })
      |> JumpTickets.External.Notion.Parser.parse_ticket_page()

    {:ok, ticket}
  end

  # =============================================
  # === BEGIN FIXED NOTION CREATE TICKET API ===
  # =============================================
  @doc """
  Creates a ticket in Notion with fixed TLS settings.
  """
  def create_ticket_fixed(%Ticket{} = ticket) do
    db_id = Application.get_env(:jump_tickets, :notion_db_id)
    token = Application.get_env(:notionex, :bearer_token)
    url = ~c"https://api.notion.com/v1/pages"
    
    # Prepare the request body
    properties = %{
      "Title" => %{
        "title" => [%{"text" => %{"content" => ticket.title}}]
      }
    }
    
    # Add additional properties if available
    properties = if ticket.intercom_conversations do
      Map.put(properties, "Intercom Conversations", %{
        "rich_text" => [%{"text" => %{"content" => ticket.intercom_conversations}}]
      })
    else
      properties
    end
    
    # Create the request body
    body = Jason.encode!(%{
      "parent" => %{"database_id" => db_id},
      "properties" => properties,
      "children" => [
        %{
          "object" => "block",
          "type" => "paragraph",
          "paragraph" => %{
            "rich_text" => [
              %{
                "type" => "text",
                "text" => %{
                  "content" => ticket.summary || ""
                }
              }
            ]
          }
        }
      ]
    })
    
    # Set up headers
    headers = [
      {~c"Authorization", ~c"Bearer #{token}"},
      {~c"Notion-Version", ~c"2022-06-28"},
      {~c"Content-Type", ~c"application/json"}
    ]
    
    # Configure SSL options
    http_options = [
      ssl: [
        verify: :verify_none,
        versions: [:'tlsv1.2'],
        ciphers: :ssl.cipher_suites(:all, :'tlsv1.2'),
        customize_hostname_check: [
          match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
        ],
        depth: 99,
        cacerts: :public_key.cacerts_get()
      ],
      timeout: 60000
    ]
    
    # Make the request
    case :httpc.request(:post, {url, headers, ~c"application/json", String.to_charlist(body)}, http_options, []) do
      {:ok, {{_, 200, _}, _, response}} ->
        response_str = List.to_string(response)
        page = Jason.decode!(response_str)
        ticket = Parser.parse_ticket_page(page)
        {:ok, ticket}
        
      {:ok, {{_, status, _}, _, response}} ->
        response_str = List.to_string(response)
        {:error, "Notion API returned #{status}: #{response_str}"}
        
      {:error, reason} ->
        {:error, "HTTP error: #{inspect(reason)}"}
    end
  end
  # ============================================
  # === END FIXED NOTION CREATE TICKET API ===
  # ============================================

  # =============================================
  # === BEGIN FIXED NOTION UPDATE TICKET API ===
  # =============================================
  @doc """
  Updates a ticket in Notion with fixed TLS settings.
  """
  def update_ticket_fixed(page_id, updates) do
    token = Application.get_env(:notionex, :bearer_token)
    url = ~c"https://api.notion.com/v1/pages/#{page_id}"
    
    # Prepare properties to update
    properties = %{}
    
    # Add slack_channel if present - as rich_text instead of url
    properties = if Map.has_key?(updates, :slack_channel) do
      Map.put(properties, "Slack Channel", %{
        "rich_text" => [%{"text" => %{"content" => updates.slack_channel}}]
      })
    else
      properties
    end
    
    # Add intercom_conversations if present
    properties = if Map.has_key?(updates, :intercom_conversations) do
      Map.put(properties, "Intercom Conversations", %{
        "rich_text" => [%{"text" => %{"content" => updates.intercom_conversations}}]
      })
    else
      properties
    end
    
    # Create the request body
    body = Jason.encode!(%{
      "properties" => properties
    })
    
    # Set up headers
    headers = [
      {~c"Authorization", ~c"Bearer #{token}"},
      {~c"Notion-Version", ~c"2022-06-28"},
      {~c"Content-Type", ~c"application/json"}
    ]
    
    # Configure SSL options
    http_options = [
      ssl: [
        verify: :verify_none,
        versions: [:'tlsv1.2'],
        ciphers: :ssl.cipher_suites(:all, :'tlsv1.2'),
        customize_hostname_check: [
          match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
        ],
        depth: 99,
        cacerts: :public_key.cacerts_get()
      ],
      timeout: 60000
    ]
    
    # Make the request
    case :httpc.request(:patch, {url, headers, ~c"application/json", String.to_charlist(body)}, http_options, []) do
      {:ok, {{_, 200, _}, _, response}} ->
        response_str = List.to_string(response)
        page = Jason.decode!(response_str)
        # Use the fully qualified name for the Parser module
        ticket = JumpTickets.External.Notion.Parser.parse_ticket_page(page)
        {:ok, ticket}
        
      {:ok, {{_, status, _}, _, response}} ->
        response_str = List.to_string(response)
        {:error, "Notion API returned #{status}: #{response_str}"}
        
      {:error, reason} ->
        {:error, "HTTP error: #{inspect(reason)}"}
    end
  end
  # ============================================
  # === END FIXED NOTION UPDATE TICKET API ===
  # ============================================

  def update_ticket(page_id, properties_to_update) when is_map(properties_to_update) do
    notion_properties =
      properties_to_update
      |> Enum.reduce(%{}, fn {key, value}, acc ->
        case key do
          :title ->
            Map.put(acc, "Title", %{
              title: [%{text: %{content: value}}]
            })

          :intercom_conversations ->
            Map.put(acc, "Intercom Conversations", %{
              rich_text: [%{text: %{content: value}}]
            })

          :slack_channel ->
            Map.put(acc, "Slack Channel", %{
              rich_text: [%{text: %{content: value}}]
            })

          _ ->
            acc
        end
      end)

    result =
      Notionex.API.update_page_properties(%{
        page_id: page_id,
        properties: notion_properties
      })

    updated_ticket = result |> JumpTickets.External.Notion.Parser.parse_ticket_page()

    {:ok, updated_ticket}
  end

  # =======================================
  # === BEGIN HTTPC BASED TEST FUNCTION ===
  # =======================================
  # You could modify the test_notion_connection function to use :httpc instead
  def test_notion_connection() do
    url = 'https://api.notion.com/v1/databases/#{Application.get_env(:jump_tickets, :notion_db_id)}/query'
    headers = [
      {'Authorization', 'Bearer #{Application.get_env(:notionex, :bearer_token)}'},
      {'Notion-Version', '2022-06-28'},
      {'Content-Type', 'application/json'}
    ]
    body = Jason.encode!(%{page_size: 10})
    
    IO.puts("Testing with :httpc")
    case :httpc.request(:post, {url, headers, 'application/json', body}, [], []) do
      {:ok, {{_, status, _}, _, response}} ->
        IO.puts("Status: #{status}")
        IO.puts("Response: #{response}")
        {:ok, response}
      error ->
        IO.puts("Error: #{inspect(error)}")
        error
    end
  end
  # ======================================
  # === END HTTPC BASED TEST FUNCTION ===
  # ======================================

  # =============================================
  # === BEGIN HTTPOISON DEBUGGING AND FIXES ===
  # =============================================
  
  @doc """
  Tests HTTPoison connection with special options to diagnose and fix issues.
  Use this to test if HTTPoison can connect to the Notion API with optimized settings.
  """
  def test_with_httpoison() do
    url = "https://api.notion.com/v1/databases/#{Application.get_env(:jump_tickets, :notion_db_id)}/query"
    headers = [
      {"Authorization", "Bearer #{Application.get_env(:notionex, :bearer_token)}"},
      {"Notion-Version", "2022-06-28"},
      {"Content-Type", "application/json"}
    ]
    body = Jason.encode!(%{page_size: 10})
    
    IO.puts("Testing direct HTTPoison call with optimized settings")
    IO.puts("URL: #{url}")
    
    # Use all possible options to overcome DNS issues
    options = [
      hackney: [
        pool: false,
        use_default_pool: false,
        insecure: true,
        timeout: 60_000,
        connect_timeout: 60_000,
        recv_timeout: 60_000,
        ipv6_enabled: false,
        inet6: false,
        ssl_options: [
          verify: :verify_none,
          secure: false,
          depth: 3
        ]
      ],
      timeout: 60_000,
      recv_timeout: 60_000
    ]
    
    case HTTPoison.post(url, body, headers, options) do
      {:ok, response} ->
        IO.puts("Success! Status: #{response.status_code}")
        IO.puts("Response preview: #{String.slice(response.body, 0, 100)}")
        {:ok, response}
      {:error, error} ->
        IO.puts("Error: #{inspect(error)}")
        {:error, error}
    end
  end
  
  @doc """
  Comprehensive diagnostic tool for HTTPoison DNS issues.
  Run this function to see exactly what's happening with DNS resolution.
  """
  def debug_httpoison() do
    IO.puts("Debugging HTTPoison configuration:")
    
    # Check Erlang DNS resolution
    IO.puts("\n1. Testing Erlang DNS resolution:")
    case :inet.gethostbyname('api.notion.com') do
      {:ok, hostent} ->
        addresses = hostent |> elem(5) |> Enum.map(&:inet.ntoa/1) |> Enum.join(", ")
        IO.puts("✓ Resolved api.notion.com to: #{addresses}")
      {:error, reason} ->
        IO.puts("✗ Failed to resolve api.notion.com: #{reason}")
    end
    
    # Check HTTPoison settings
    IO.puts("\n2. Current HTTPoison settings:")
    hackney_opts = Application.get_env(:httpoison, :hackney, [])
    IO.puts("HTTPoison hackney options: #{inspect(hackney_opts)}")
    
    # Try to set up DNS servers
    :inet_db.set_lookup([:file, :dns])
    :inet_db.add_ns({8, 8, 8, 8})  # Google DNS
    :inet_db.add_ns({1, 1, 1, 1})  # Cloudflare DNS
    
    # Try multiple test endpoints
    endpoints = [
      {"httpbin.org", "https://httpbin.org/ip"},
      {"example.com", "https://example.com"},
      {"api.notion.com", "https://api.notion.com/v1"}
    ]
    
    IO.puts("\n3. Testing HTTPoison connectivity to various endpoints:")
    Enum.each(endpoints, fn {name, url} ->
      IO.puts("\nTesting connection to #{name}:")
      case HTTPoison.get(url, [], hackney: [pool: false]) do
        {:ok, response} ->
          IO.puts("✓ Connected to #{name} (status: #{response.status_code})")
        {:error, error} ->
          IO.puts("✗ Failed to connect to #{name}: #{inspect(error)}")
      end
    end)
    
    # Apply temporary fixes and test again
    IO.puts("\n4. Applying temporary fixes and testing Notion API:")
    apply_httpoison_fixes()
    test_with_httpoison()
    
    :ok
  end
  
  @doc """
  Applies comprehensive fixes to HTTPoison configuration.
  Call this function to optimize HTTPoison settings for Notion API.
  """
  def apply_httpoison_fixes() do
    IO.puts("Applying HTTPoison DNS resolution fixes...")
    
    # Configure hackney
    :ok = Application.put_env(:hackney, :use_default_pool, false)
    :ok = Application.put_env(:hackney, :max_connections, 100)
    :ok = Application.put_env(:hackney, :timeout, 60_000)
    :ok = Application.put_env(:hackney, :connect_timeout, 60_000)
    :ok = Application.put_env(:hackney, :recv_timeout, 60_000)
    :ok = Application.put_env(:hackney, :follow_redirect, true)
    :ok = Application.put_env(:hackney, :max_redirect, 5)
    :ok = Application.put_env(:hackney, :ipv6_enabled, false)
    :ok = Application.put_env(:hackney, :inet6, false)
    
    # Set SSL options
    :ok = Application.put_env(:hackney, :ssl_options, [
      verify: :verify_none,
      secure: false,
      depth: 3
    ])
    
    # Configure HTTPoison
    :ok = Application.put_env(:httpoison, :hackney, [
      use_default_pool: false,
      pool: false,
      timeout: 60_000,
      connect_timeout: 60_000,
      recv_timeout: 60_000,
      ipv6_enabled: false,
      inet6: false,
      insecure: true,
      follow_redirect: true,
      max_redirect: 5,
      ssl_options: [
        verify: :verify_none,
        secure: false,
        depth: 3
      ]
    ])
    
    # Try to establish DNS entries
    case System.cmd("ping", ["api.notion.com", "-n", "1"]) do
      {output, 0} ->
        case Regex.run(~r/\[([0-9a-f:.]+)\]/i, output) do
          [_, ip] ->
            IO.puts("Found IP for api.notion.com: #{ip}")
            # Add host entry to :inet hosts
            try_add_host_entry("api.notion.com", ip)
          _ ->
            IO.puts("Could not extract IP from ping output")
        end
      _ ->
        IO.puts("Ping command failed")
    end
    
    IO.puts("HTTPoison fixes applied")
    :ok
  end
  
  # Helper function to add host entry
  defp try_add_host_entry(hostname, ip) do
    hostname_charlist = String.to_charlist(hostname)
    
    # Try to parse IP
    ip_tuple = 
      if String.contains?(ip, ":") do
        # IPv6
        parts = String.split(ip, ":")
        parts = Enum.map(parts, fn part -> 
          case Integer.parse(part, 16) do
            {int, _} -> int
            :error -> 0
          end
        end)
        List.to_tuple(parts)
      else
        # IPv4
        parts = String.split(ip, ".")
        parts = Enum.map(parts, &String.to_integer/1)
        List.to_tuple(parts)
      end
    
    # Add to hosts
    :inet_db.add_host(ip_tuple, [hostname_charlist])
    IO.puts("Added host entry: #{hostname} -> #{ip}")
  rescue
    e -> IO.puts("Error adding host entry: #{inspect(e)}")
  end
  
  @doc """
  Direct implementation of fetch_all_pages using HTTPoison instead of Notionex.
  Use this as a fallback if the Notionex library continues to have DNS issues.
  """
  def direct_fetch_all_pages(db_id, start_cursor \\ nil, accumulated_results \\ []) do
    IO.puts("Attempting direct fetch from Notion database: #{db_id}")
    
    # Apply fixes first
    apply_httpoison_fixes()
    
    url = "https://api.notion.com/v1/databases/#{db_id}/query"
    headers = [
      {"Authorization", "Bearer #{Application.get_env(:notionex, :bearer_token)}"},
      {"Notion-Version", "2022-06-28"},
      {"Content-Type", "application/json"}
    ]
    
    # Build body with pagination
    body_map = %{page_size: 100}
    body_map = if start_cursor, do: Map.put(body_map, :start_cursor, start_cursor), else: body_map
    body = Jason.encode!(body_map)
    
    # Use all possible options
    options = [
      hackney: [
        pool: false,
        insecure: true,
        timeout: 60_000,
        connect_timeout: 60_000,
        recv_timeout: 60_000,
        ipv6_enabled: false,
        ssl_options: [verify: :verify_none]
      ]
    ]
    
    case HTTPoison.post(url, body, headers, options) do
      {:ok, %{status_code: 200, body: response_body}} ->
        # Parse the JSON response
        decoded = Jason.decode!(response_body)
        results = Map.get(decoded, "results", [])
        has_more = Map.get(decoded, "has_more", false)
        next_cursor = Map.get(decoded, "next_cursor")
        
        # Parse the results
        parsed_results = Enum.map(results, &__MODULE__.Parser.parse_ticket_page/1)
        
        # Handle pagination
        if has_more && next_cursor do
          direct_fetch_all_pages(db_id, next_cursor, accumulated_results ++ parsed_results)
        else
          {:ok, accumulated_results ++ parsed_results}
        end
        
      {:ok, %{status_code: status_code, body: body}} ->
        {:error, "Failed with status #{status_code}: #{body}"}
        
      {:error, error} ->
        {:error, "HTTP error: #{inspect(error)}"}
    end
  end
  # ============================================
  # === END HTTPOISON DEBUGGING AND FIXES ===
  # ============================================

  # =================================================
  # === BEGIN TLS HANDSHAKE ISSUE FIX FUNCTIONS ===
  # =================================================
  @doc """
  Tests connection to Notion API with fixed TLS settings to overcome handshake issues.
  This function uses :httpc with explicit SSL options for TLS compatibility.
  """
  def test_notion_with_fixed_tls() do
    db_id = Application.get_env(:jump_tickets, :notion_db_id)
    token = Application.get_env(:notionex, :bearer_token)
    
    url = 'https://api.notion.com/v1/databases/#{db_id}/query'
    headers = [
      {'Authorization', 'Bearer #{token}'},
      {'Notion-Version', '2022-06-28'},
      {'Content-Type', 'application/json'}
    ]
    body = String.to_charlist(Jason.encode!(%{page_size: 10}))
    
    # Configure SSL options specifically to fix TLS handshake errors
    http_options = [
      ssl: [
        verify: :verify_none,
        versions: [:'tlsv1.2'],  # Force TLSv1.2 which is widely compatible
        ciphers: :ssl.cipher_suites(:all, :'tlsv1.2'),  # All available TLSv1.2 ciphers
        customize_hostname_check: [
          match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
        ],
        depth: 99,  # Allow deep certificate chains
        cacerts: :public_key.cacerts_get()  # Use system CA certificates
      ],
      timeout: 60000,
      connect_timeout: 60000
    ]
    
    IO.puts("Testing connection to Notion API with fixed TLS settings")
    IO.puts("URL: #{url}")
    
    case :httpc.request(:post, {url, headers, 'application/json', body}, http_options, []) do
      {:ok, {{_, status, _}, resp_headers, response}} ->
        IO.puts("Success! Status: #{status}")
        IO.puts("Response preview: #{String.slice(List.to_string(response), 0, 100)}")
        
        # Also log headers to help with debugging
        IO.puts("Response headers:")
        Enum.each(resp_headers, fn {name, value} ->
          IO.puts("  #{List.to_string(name)}: #{List.to_string(value)}")
        end)
        
        {:ok, response}
      
      {:error, reason} ->
        IO.puts("Error: #{inspect(reason)}")
        {:error, reason}
    end
  end
  
  @doc """
  A complete replacement for fetch_all_pages that uses fixed TLS settings.
  This function bypasses the Notionex library to work directly with the Notion API.
  """
  def fetch_all_pages_fixed_tls(db_id, start_cursor \\ nil, accumulated_results \\ []) do
    IO.puts("Fetching pages from Notion database with fixed TLS settings: #{db_id}")
    
    url = 'https://api.notion.com/v1/databases/#{db_id}/query'
    headers = [
      {'Authorization', 'Bearer #{Application.get_env(:notionex, :bearer_token)}'},
      {'Notion-Version', '2022-06-28'},
      {'Content-Type', 'application/json'}
    ]
    
    # Create request body with pagination support
    body_map = %{page_size: 100}
    body_map = if start_cursor, do: Map.put(body_map, :start_cursor, start_cursor), else: body_map
    body = String.to_charlist(Jason.encode!(body_map))
    
    # Configure SSL options to fix TLS handshake issues
    http_options = [
      ssl: [
        verify: :verify_none,
        versions: [:'tlsv1.2'],
        ciphers: :ssl.cipher_suites(:all, :'tlsv1.2'),
        customize_hostname_check: [
          match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
        ],
        depth: 99,
        cacerts: :public_key.cacerts_get()
      ],
      timeout: 60000
    ]
    
    case :httpc.request(:post, {url, headers, 'application/json', body}, http_options, []) do
      {:ok, {{_, 200, _}, _, response_chars}} ->
        # Convert response to string and parse JSON
        response_str = List.to_string(response_chars)
        decoded = Jason.decode!(response_str)
        
        results = Map.get(decoded, "results", [])
        has_more = Map.get(decoded, "has_more", false)
        next_cursor = Map.get(decoded, "next_cursor")
        
        # Parse the results
        parsed_results = Enum.map(results, &__MODULE__.Parser.parse_ticket_page/1)
        
        # Handle pagination if needed
        if has_more && next_cursor do
          fetch_all_pages_fixed_tls(db_id, next_cursor, accumulated_results ++ parsed_results)
        else
          {:ok, accumulated_results ++ parsed_results}
        end
        
      {:ok, {{_, status, _}, _, response_chars}} ->
        response_str = List.to_string(response_chars)
        {:error, "Notion API error: HTTP #{status} - #{response_str}"}
        
      {:error, reason} ->
        {:error, "HTTP request failed: #{inspect(reason)}"}
    end
  end
  
  @doc """
  Override that calls the fixed TLS version of fetch_all_pages.
  You can use this as a drop-in replacement for the original query_db function.
  """
  def query_db_fixed() do
    db_id = Application.get_env(:jump_tickets, :notion_db_id)
    fetch_all_pages_fixed_tls(db_id)
  end
  # ================================================
  # === END TLS HANDSHAKE ISSUE FIX FUNCTIONS ===
  # ================================================

  


end

defmodule JumpTickets.External.Notion.Parser do
  @moduledoc false
  alias JumpTickets.Ticket

  require Logger

  def parse_response(response) do
    case response do
      %Notionex.Object.List{results: results} ->
        Enum.map(results, &parse_ticket_page/1)

      _ ->
        {:error, "Invalid response format"}
    end
  end

  def parse_ticket_page(page) do
    notion_url = Map.get(page, "url", Map.get(page, :url))
    notion_id = Map.get(page, "id", Map.get(page, :id))
    properties = Map.get(page, "properties", Map.get(page, :properties))

    %Ticket{
      ticket_id: Map.get(properties, "ID") |> extract_id(),
      notion_id: notion_id,
      notion_url: notion_url,
      title: Map.get(properties, "Title") |> extract_title(),
      intercom_conversations:
        Map.get(properties, "Intercom Conversations") |> extract_rich_text(),
      summary: Map.get(properties, "children") |> extract_rich_text(),
      slack_channel: Map.get(properties, "Slack Channel") |> extract_rich_text()
    }
  end

  defp extract_id(nil), do: nil

  defp extract_id(%{"unique_id" => %{"number" => number, "prefix" => prefix}}) do
    "#{prefix}-#{number}"
  end

  # Extract plain text from a title property
  defp extract_title(nil), do: nil

  defp extract_title(%{"title" => title}) do
    case title do
      [%{"plain_text" => text} | _] -> text
      _ -> nil
    end
  end

  defp extract_title(_), do: nil

  # Extract plain text from a rich_text property
  defp extract_rich_text(nil), do: nil

  defp extract_rich_text(%{"rich_text" => rich_text}) do
    case rich_text do
      [%{"plain_text" => text} | _] -> text
      _ -> nil
    end
  end

  defp extract_rich_text(_), do: nil
end
