defmodule KbaseBot.Federation.Transport.HTTPSTest do
  # async: false — mutates the :federation_allow_private_endpoints app env.
  use ExUnit.Case, async: false

  alias KbaseBot.Federation.Transport.HTTPS

  test "refuses loopback, private, link-local and metadata addresses" do
    assert {:error, :private_address} =
             HTTPS.ensure_safe("http://169.254.169.254/latest/meta-data/")

    assert {:error, :private_address} = HTTPS.ensure_safe("http://127.0.0.1:4040/inbox")
    assert {:error, :private_address} = HTTPS.ensure_safe("https://10.0.0.5/x")
    assert {:error, :private_address} = HTTPS.ensure_safe("https://192.168.1.10/x")
    assert {:error, :private_address} = HTTPS.ensure_safe("https://172.16.0.1/x")
    assert {:error, :private_address} = HTTPS.ensure_safe("https://100.100.1.1/x")
    assert {:error, :private_address} = HTTPS.ensure_safe("http://0.0.0.0/x")
    assert {:error, :private_address} = HTTPS.ensure_safe("http://[::1]/x")
    assert {:error, :private_address} = HTTPS.ensure_safe("http://[fe80::1]/x")
    assert {:error, :private_address} = HTTPS.ensure_safe("http://[fd00::1]/x")
    assert {:error, :private_address} = HTTPS.ensure_safe("http://[::ffff:127.0.0.1]/x")
  end

  test "refuses non-http schemes and malformed addresses" do
    assert {:error, :bad_scheme} = HTTPS.ensure_safe("file:///etc/passwd")
    assert {:error, :bad_scheme} = HTTPS.ensure_safe("gopher://evil")
    assert {:error, _} = HTTPS.ensure_safe("not a url")
    assert {:error, :bad_address} = HTTPS.ensure_safe(nil)
    assert {:error, :bad_address} = HTTPS.ensure_safe(%{})
  end

  test "accepts public literal addresses" do
    assert :ok = HTTPS.ensure_safe("https://93.184.216.34/federation/inbox")
  end

  test "escape hatch allows private endpoints for local multi-bot testing" do
    Application.put_env(:kbase_bot, :federation_allow_private_endpoints, true)

    on_exit(fn ->
      Application.delete_env(:kbase_bot, :federation_allow_private_endpoints)
    end)

    assert :ok = HTTPS.ensure_safe("http://127.0.0.1:4041/federation/inbox")
  end
end
