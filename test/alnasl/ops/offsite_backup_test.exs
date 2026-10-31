defmodule Alnasl.Ops.OffsiteBackupTest do
  @moduledoc """
  The off-site backup: reading the environment (off, half, wrong, right),
  a push end to end against a stub bucket - signed, encrypted, a real
  snapshot inside - what a refusal leaves in the run log, and the status
  `/healthz` repeats.
  """

  use Alnasl.DataCase, async: false

  alias Alnasl.Ops.{Age, OffsiteBackup, OffsiteBackupRun}
  alias Alnasl.Repo

  @moduletag :capture_log

  setup do
    {secret, public} = Age.generate_identity()

    config = [
      recipients: [public],
      stale_hours: 36,
      s3: [
        endpoint: "https://s3.example.org",
        bucket: "backups",
        region: "eu-central",
        prefix: "alnasl",
        access_key_id: "AKIDEXAMPLE0001",
        secret_access_key: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"
      ]
    ]

    %{config: config, secret: secret, public: public}
  end

  defp env(map), do: fn name -> Map.get(map, name) end

  defp full_env(public) do
    %{
      "OFFSITE_BACKUP_RECIPIENTS" => public,
      "OFFSITE_BACKUP_S3_ENDPOINT" => "https://s3.example.org/",
      "OFFSITE_BACKUP_S3_BUCKET" => "backups",
      "OFFSITE_BACKUP_S3_ACCESS_KEY_ID" => "AKIDEXAMPLE0001",
      "OFFSITE_BACKUP_S3_SECRET_ACCESS_KEY" => "very-secret-value"
    }
  end

  describe "from_env/1" do
    test "nothing set is off" do
      assert :disabled = OffsiteBackup.from_env(env(%{}))
      assert :disabled = OffsiteBackup.from_env(env(%{"OFFSITE_BACKUP_S3_BUCKET" => "  "}))
    end

    test "half a configuration names what is missing, never a value", %{public: public} do
      env = public |> full_env() |> Map.delete("OFFSITE_BACKUP_S3_SECRET_ACCESS_KEY")
      assert {:error, message} = OffsiteBackup.from_env(env(env))
      assert message =~ "OFFSITE_BACKUP_S3_SECRET_ACCESS_KEY"
      refute message =~ "AKIDEXAMPLE0001"
    end

    test "a recipient that is not an age key is refused", %{public: public} do
      env = Map.put(full_env(public), "OFFSITE_BACKUP_RECIPIENTS", public <> ",ssh-ed25519 AAAA")
      assert {:error, message} = OffsiteBackup.from_env(env(env))
      assert message =~ "entry 2"
    end

    test "plain http to somewhere else is refused", %{public: public} do
      env = Map.put(full_env(public), "OFFSITE_BACKUP_S3_ENDPOINT", "http://s3.example.org")
      assert {:error, message} = OffsiteBackup.from_env(env(env))
      assert message =~ "https"
    end

    test "a bad stale-hours is refused", %{public: public} do
      env = Map.put(full_env(public), "OFFSITE_BACKUP_STALE_HOURS", "soon")
      assert {:error, _} = OffsiteBackup.from_env(env(env))
    end

    test "everything set is a configuration with the defaults", %{public: public} do
      assert {:ok, config} = OffsiteBackup.from_env(env(full_env(public)))
      assert config[:recipients] == [public]
      assert config[:stale_hours] == 36
      assert config[:s3][:endpoint] == "https://s3.example.org"
      assert config[:s3][:region] == "us-east-1"
      assert config[:s3][:prefix] == "alnasl"
      assert OffsiteBackup.enabled?(config)
    end
  end

  describe "push/1" do
    test "not configured is :disabled and records nothing" do
      assert :disabled = OffsiteBackup.push(config: [])
      assert OffsiteBackup.runs() == []
    end

    test "sends a signed PUT of an encrypted, gzipped snapshot of the database",
         %{config: config, secret: secret} do
      test = self()

      Req.Test.stub(OffsiteBackup, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn, length: 100_000_000)

        send(
          test,
          {:put, conn.method, conn.request_path, Plug.Conn.get_req_header(conn, "authorization"),
           body}
        )

        Plug.Conn.send_resp(conn, 200, "")
      end)

      now = ~U[2026-10-31 03:00:00Z]
      assert {:ok, key} = OffsiteBackup.push(config: config, now: now)
      assert key == "alnasl/alnasl-20261031T030000Z.sqlite.gz.age"

      assert_receive {:put, "PUT", path, [authorization], body}
      assert path == "/backups/alnasl/alnasl-20261031T030000Z.sqlite.gz.age"
      assert String.starts_with?(authorization, "AWS4-HMAC-SHA256")
      refute authorization =~ "wJalrXUtnFEMI"

      assert String.starts_with?(body, "age-encryption.org/v1\n")
      assert {:ok, gz} = Age.decrypt(body, secret)
      assert "SQLite format 3" <> <<0>> <> _ = :zlib.gunzip(gz)

      assert [%OffsiteBackupRun{status: "ok", object_key: ^key, bytes: bytes}] =
               OffsiteBackup.runs()

      assert bytes == byte_size(body)
      assert File.ls!(OffsiteBackup.work_dir()) == []
    end

    test "a refusal keeps only the S3 error code", %{config: config} do
      Req.Test.stub(OffsiteBackup, fn conn ->
        Plug.Conn.send_resp(conn, 403, """
        <?xml version="1.0" encoding="UTF-8"?>
        <Error><Code>SignatureDoesNotMatch</Code><AWSAccessKeyId>AKIDEXAMPLE0001</AWSAccessKeyId><StringToSign>AWS4-HMAC-SHA256 secret stuff</StringToSign></Error>
        """)
      end)

      assert {:error, reason} = OffsiteBackup.push(config: config)
      assert reason == "storage answered HTTP 403 (SignatureDoesNotMatch)"

      assert [%OffsiteBackupRun{status: "failed", error: error}] = OffsiteBackup.runs()
      assert error == reason
      refute error =~ "AKIDEXAMPLE0001"
      assert File.ls!(OffsiteBackup.work_dir()) == []
    end

    test "a snapshot that fails is a failed run, and nothing is sent", %{config: config} do
      Req.Test.stub(OffsiteBackup, fn _conn -> flunk("nothing should be sent") end)

      assert {:error, "could not snapshot the database: disk full"} =
               OffsiteBackup.push(
                 config: config,
                 snapshot: fn _path -> {:error, "could not snapshot the database: disk full"} end
               )

      assert [%OffsiteBackupRun{status: "failed"}] = OffsiteBackup.runs()
    end
  end

  describe "status/2" do
    defp run(status, finished_at) do
      Repo.insert!(%OffsiteBackupRun{
        status: status,
        started_at: finished_at,
        finished_at: finished_at
      })
    end

    test "not configured is :disabled" do
      assert OffsiteBackup.status([]) == :disabled
    end

    test "configured and never sent is :stale", %{config: config} do
      assert OffsiteBackup.status(config) == :stale
    end

    test "a recent success is :ok, an old one :stale", %{config: config} do
      now = ~U[2026-10-31 12:00:00Z]
      run("ok", ~U[2026-10-31 03:00:00Z])
      assert OffsiteBackup.status(config, now) == :ok
      assert OffsiteBackup.status(config, DateTime.add(now, 40, :hour)) == :stale
    end

    test "a failure after a success is :failing", %{config: config} do
      now = ~U[2026-10-31 12:00:00Z]
      run("ok", ~U[2026-10-31 03:00:00Z])
      run("failed", ~U[2026-10-31 04:00:00Z])
      assert OffsiteBackup.status(config, now) == :failing
    end
  end

  describe "the scheduler" do
    test "a success waits a day, a failure an hour" do
      state = %{interval: :timer.hours(24), retry: :timer.hours(1)}
      assert OffsiteBackup.Scheduler.next_in({:ok, "k"}, state) == :timer.hours(24)
      assert OffsiteBackup.Scheduler.next_in({:error, "x"}, state) == :timer.hours(1)
    end
  end
end
