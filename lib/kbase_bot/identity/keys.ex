defmodule KbaseBot.Identity.Keys do
  @moduledoc """
  The bot's own Ed25519 federation identity.

  Keys live in a JSON file at `:federation_key_path` (env FEDERATION_KEY_PATH);
  the principal id is `"sha256:" <> hex(sha256(pubkey))`. Generate with
  `mix kbase_bot.gen_identity <path>`.
  """

  @cache_key {__MODULE__, :keypair}

  @doc "Own keypair, cached after first load. {:error, :no_identity} when unconfigured."
  @spec own_keypair() :: {:ok, {binary(), binary()}} | {:error, term()}
  def own_keypair do
    case :persistent_term.get(@cache_key, nil) do
      nil ->
        with path when is_binary(path) <- key_path(),
             {:ok, pair} <- load(path) do
          :persistent_term.put(@cache_key, pair)
          {:ok, pair}
        else
          nil -> {:error, :no_identity}
          err -> err
        end

      pair ->
        {:ok, pair}
    end
  end

  @doc "Drop the cached keypair (key file changed, e.g. after a rotation)."
  @spec reset_cache() :: :ok
  def reset_cache do
    :persistent_term.erase(@cache_key)
    :ok
  end

  @spec own_principal_id() :: {:ok, String.t()} | {:error, term()}
  def own_principal_id do
    with {:ok, {pub, _priv}} <- own_keypair(), do: {:ok, fingerprint(pub)}
  end

  @doc "Principal id for a raw Ed25519 public key."
  @spec fingerprint(binary()) :: String.t()
  def fingerprint(pub) when is_binary(pub) do
    "sha256:" <> Base.encode16(:crypto.hash(:sha256, pub), case: :lower)
  end

  @spec load(Path.t()) :: {:ok, {binary(), binary()}} | {:error, term()}
  def load(path) do
    case File.read(path) do
      {:ok, raw} ->
        with {:ok, %{"ed25519_pub" => pub_b64, "ed25519_priv" => priv_b64}} <-
               Jason.decode(raw),
             {:ok, pub} <- Base.decode64(pub_b64),
             {:ok, priv} <- Base.decode64(priv_b64) do
          {:ok, {pub, priv}}
        else
          _ -> {:error, :invalid_key_file}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Generate a fresh keypair to `path` (mode 0600). Refuses to overwrite."
  @spec generate_to(Path.t()) :: {:ok, String.t()} | {:error, term()}
  def generate_to(path) do
    if File.exists?(path) do
      {:error, :already_exists}
    else
      {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)

      json =
        Jason.encode!(%{
          "ed25519_pub" => Base.encode64(pub),
          "ed25519_priv" => Base.encode64(priv)
        })

      File.mkdir_p!(Path.dirname(path))
      File.write!(path, json)
      File.chmod!(path, 0o600)
      {:ok, fingerprint(pub)}
    end
  end

  defp key_path, do: Application.get_env(:kbase_bot, :federation_key_path)
end
