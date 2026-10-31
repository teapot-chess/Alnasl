defmodule Alnasl.Ops.ErrorReportsTest do
  @moduledoc """
  The sanitizer is the specification: what a crash report may keep, and
  what never gets into the table. Then the storage (one row per kind, a
  count, a cap) and the path from `:logger` to the row.
  """

  use Alnasl.DataCase, async: false

  alias Alnasl.Ops.{ErrorReport, ErrorReports}
  alias Alnasl.Ops.ErrorReports.{LoggerHandler, Recorder}
  alias Alnasl.Repo

  defp crash(fun) do
    fun.()
    flunk("expected a crash")
  rescue
    error -> {error, __STACKTRACE__}
  end

  defp report(fun), do: fun |> crash() |> ErrorReports.from_crash()

  # A value the compiler cannot see through, so a pattern that does not
  # match it is a crash at run time and not a warning at compile time.
  defp opaque(value), do: Process.get(:never_set, value)

  describe "from_crash/1, what is kept out" do
    test "a FunctionClauseError keeps the arity and drops the arguments" do
      fc =
        report(fn ->
          apply(String, :to_integer, [%{email: "player@example.org", secret: "s3cret-value"}])
        end)

      assert fc.kind == "FunctionClauseError"
      refute fc.message =~ "player@example.org"
      refute fc.stacktrace =~ "s3cret"
      refute fc.stacktrace =~ "player@example.org"
      assert fc.stacktrace =~ "String.to_integer/1"
    end

    test "a MatchError's term is removed from the message" do
      value = %{name: "Magnus", token: "abcdefghijklmnopqrstuvwxyz0123"}
      report = report(fn -> {:ok, _} = opaque({:error, value}) end)

      assert report.kind == "MatchError"
      # Elixir prints the term on a paragraph of its own, which goes; an older
      # one put it after the colon, where it becomes [term]. Either way: gone.
      assert report.message =~ "no match of right hand side value"
      refute report.message =~ "Magnus"
      refute report.message =~ "abcdefghijklmnopqrstuvwxyz"
    end

    test "e-mail addresses and long tokens are scrubbed, and only the first paragraph stays" do
      message =
        "could not reach player@example.org with key ABCDEFGHIJKLMNOPQRSTUVWXYZ012345\n\nsecond paragraph with more"

      clean = ErrorReports.sanitize_message(message)
      assert clean =~ "[email]"
      assert clean =~ "[redacted]"
      refute clean =~ "example.org"
      refute clean =~ "second paragraph"
    end

    test "an inspected term after a colon becomes [term]" do
      assert ErrorReports.sanitize_message(~s(key :pin not found in: %{pin: "4711"})) ==
               "key :pin not found in: [term]"
    end

    test "messages are capped" do
      assert String.length(ErrorReports.sanitize_message(String.duplicate("word ", 200))) <= 300
    end

    test "an exit keeps only the shape of its reason" do
      report = ErrorReports.from_crash({{:shutdown, %{email: "a@example.org"}}, []})
      assert report.kind == "exit"
      refute report.message =~ "example.org"
      assert report.message =~ ":shutdown"
    end

    test "4xx-shaped exceptions are not crashes" do
      assert :ignore = ErrorReports.from_crash({%AlnaslWeb.NotFound{}, []})

      assert :ignore =
               ErrorReports.from_crash(
                 {%Phoenix.Router.NoRouteError{conn: %Plug.Conn{}, router: AlnaslWeb.Router}, []}
               )
    end

    test "the same bug is the same fingerprint, a different one is not" do
      a = report(fn -> {:ok, _} = opaque({:error, 1}) end)
      b = report(fn -> {:ok, _} = opaque({:error, 2}) end)
      c = report(fn -> raise ArgumentError, "nope" end)

      assert a.fingerprint == b.fingerprint
      refute a.fingerprint == c.fingerprint
    end
  end

  describe "record/2" do
    test "a second time is one more on the count, not another row" do
      report = report(fn -> raise ArgumentError, "once" end)
      t1 = ~U[2026-10-31 10:00:00Z]
      t2 = ~U[2026-10-31 11:00:00Z]

      assert {:new, row} = ErrorReports.record(report, t1)
      assert {:seen, _} = ErrorReports.record(report, t2)

      assert [%ErrorReport{count: 2, first_seen_at: ^t1, last_seen_at: ^t2}] = ErrorReports.list()
      assert row.kind == "ArgumentError"
    end

    test "at most #{200} rows; the least recently seen go first" do
      base = ~U[2026-10-01 00:00:00Z]

      for i <- 1..(ErrorReports.max_rows() + 5) do
        report = %{
          fingerprint: "fp-#{i}",
          kind: "ArgumentError",
          message: "m",
          location: nil,
          stacktrace: ""
        }

        ErrorReports.record(report, DateTime.add(base, i, :minute))
      end

      assert Repo.aggregate(ErrorReport, :count) == ErrorReports.max_rows()
      refute Repo.get_by(ErrorReport, fingerprint: "fp-1")
      assert Repo.get_by(ErrorReport, fingerprint: "fp-#{ErrorReports.max_rows() + 5}")
    end

    test "delete/1 and clear/0 forget" do
      ErrorReports.record(%{
        fingerprint: "a",
        kind: "k",
        message: "m",
        location: nil,
        stacktrace: ""
      })

      ErrorReports.record(%{
        fingerprint: "b",
        kind: "k",
        message: "m",
        location: nil,
        stacktrace: ""
      })

      [first | _] = ErrorReports.list()
      ErrorReports.delete(first.id)
      assert length(ErrorReports.list()) == 1

      ErrorReports.clear()
      assert ErrorReports.list() == []
    end
  end

  describe "the logger handler and the recorder" do
    test "a crash logged with a crash_reason ends up as a row" do
      name = :"recorder_#{System.unique_integer([:positive])}"
      pid = start_supervised!({Recorder, name: name})
      Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), pid)

      {error, stack} = crash(fn -> raise ArgumentError, "from the handler" end)

      assert :ok =
               LoggerHandler.log(
                 %{level: :error, msg: {:string, "boom"}, meta: %{crash_reason: {error, stack}}},
                 %{config: %{recorder: name}}
               )

      _ = :sys.get_state(pid)

      assert [%ErrorReport{kind: "ArgumentError", message: "from the handler"}] =
               ErrorReports.list()
    end

    test "events without a crash_reason, and 404s, are left alone" do
      name = :"recorder_#{System.unique_integer([:positive])}"
      pid = start_supervised!({Recorder, name: name})
      Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), pid)
      config = %{config: %{recorder: name}}

      assert :ok = LoggerHandler.log(%{level: :error, msg: {:string, "x"}, meta: %{}}, config)

      assert :ok =
               LoggerHandler.log(
                 %{
                   level: :error,
                   msg: {:string, "x"},
                   meta: %{crash_reason: {%AlnaslWeb.NotFound{}, []}}
                 },
                 config
               )

      _ = :sys.get_state(pid)
      assert ErrorReports.list() == []
    end

    test "a recorder that is not running loses the report and nothing else" do
      {error, stack} = crash(fn -> raise ArgumentError, "nobody listening" end)

      assert :ok =
               LoggerHandler.log(
                 %{level: :error, msg: {:string, "x"}, meta: %{crash_reason: {error, stack}}},
                 %{config: %{recorder: :no_such_recorder}}
               )
    end
  end
end
