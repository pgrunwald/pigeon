defmodule Pigeon.FCM.Config do
  @moduledoc false

  defstruct key: nil,
            uri: 'fcm.googleapis.com',
            port: 443,
            name: nil

  @type t :: %__MODULE__{
    key: binary,
    name: term,
    port: pos_integer,
    uri: charlist,
  }

  @doc ~S"""
  Returns a new `FCM.Config` with given `opts`.

  ## Examples

      iex> Pigeon.FCM.Config.new(
      ...>   name: :test,
      ...>   key: "fcm_key",
      ...>   uri: 'test.server.example.com',
      ...>   port: 5228
      ...> )
      %Pigeon.FCM.Config{key: "fcm_key", name: :test,
      port: 5228, uri: 'test.server.example.com'}
  """
  def new(opts) when is_list(opts) do
    %__MODULE__{
      name: opts[:name],
      key: opts[:key],
      uri: Keyword.get(opts, :uri, 'fcm.googleapis.com'),
      port: Keyword.get(opts, :port, 443)
    }
  end
  def new(name) when is_atom(name) do
    Application.get_env(:pigeon, :fcm)[name]
    |> Enum.to_list()
    |> Keyword.put(:name, name)
    |> new()
  end
end

defimpl Pigeon.Configurable, for: Pigeon.FCM.Config do
  @moduledoc false

  require Logger

  alias Pigeon.Encodable
  alias Pigeon.FCM.{Config, ResultParser}

  @type sock :: {:sslsocket, any, pid | {any, any}}

  # Configurable Callbacks

  @spec worker_name(any) :: atom | nil
  def worker_name(%Config{name: name}), do: name

  @spec connect(any) :: {:ok, sock} | {:error, String.t}
  def connect(%Config{uri: uri} = config) do
    case connect_socket_options(config) do
      {:ok, options} ->
        Pigeon.Http2.Client.default().connect(uri, :https, options)
    end
  end

  def connect_socket_options(config) do
    opts = [
      {:active, :once},
      {:packet, :raw},
      {:reuseaddr, true},
      {:alpn_advertised_protocols, [<<"h2">>]},
      {:reconnect, false},
      :binary
    ]
    |> add_port(config)

    {:ok, opts}
  end

  def add_port(opts, %Config{port: 443}), do: opts
  def add_port(opts, %Config{port: port}), do: [{:port, port} | opts]

  def push_headers(%Config{key: key}, _notification, opts) do
    [
      {":method", "POST"},
      {":path", "/fcm/send"},
      {"authorization", "key=#{opts[:key] || key}"},
      {"content-type", "application/json"},
      {"accept", "application/json"}
    ]
  end

  def push_payload(_config, notification, _opts) do
    Encodable.binary_payload(notification)
  end

  def handle_end_stream(_config,
                        %{body: body, status: status, error: nil},
                        notif,
                        on_response) do
    do_handle_end_stream(status, body, notif, on_response)
  end
  def handle_end_stream(_config, %{error: _error}, _notif, nil), do: :ok
  def handle_end_stream(_config, %{error: _error}, {_regids, notif}, on_response) do
    notif = %{notif | status: :unavailable}
    on_response.(notif)
  end

  defp do_handle_end_stream(200, body, notif, on_response) do
    result = Poison.decode!(body)
    notif = %{notif | status: :success}
    parse_result(notif.registration_id, result, on_response, notif)
  end
  defp do_handle_end_stream(400, _body, notif, on_response) do
    log_error("400", "Malformed JSON")
    notif = %{notif | status: :malformed_json}
    unless on_response == nil do on_response.(notif) end
  end
  defp do_handle_end_stream(401, _body, notif, on_response) do
    log_error("401", "Unauthorized")
    notif = %{notif | status: :unauthorized}
    unless on_response == nil do on_response.(notif) end
  end
  defp do_handle_end_stream(500, _body, notif, on_response) do
    log_error("500", "Internal server error")
    notif = %{notif | status: :internal_server_error}
    unless on_response == nil do on_response.(notif) end
  end
  defp do_handle_end_stream(code, body, notif, on_response) do
    reason = parse_error(body)
    log_error(code, reason)
    notif = %{notif | response: reason}
    unless on_response == nil do on_response.(notif) end
  end

  def schedule_ping(_config), do: :ok

  def reconnect?(_config), do: false

  def close(_config) do
  end

  # no on_response callback, ignore
  def parse_result(_, _, nil, _notif), do: :ok

  def parse_result(ids, %{"results" => results}, on_response, notification) do
    ResultParser.parse(ids, results, on_response, notification)
  end

  defp parse_error(data) do
    {:ok, response} = Poison.decode(data)
    response["reason"] |> Macro.underscore |> String.to_existing_atom
  end

  defp log_error(code, reason) do
    if Pigeon.debug_log?, do: Logger.error("#{reason}: #{code}")
  end
end
