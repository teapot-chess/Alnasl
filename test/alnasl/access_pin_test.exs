defmodule Alnasl.AccessPinTest do
  @moduledoc """
  The PIN there always is (`Alnasl.AccessPin`), the box's request file
  (`Alnasl.PinRequest`) and the lockout (`Alnasl.DoorGuard`). Every file
  test works in a directory of its own, never the run's data directory.
  """

  use Alnasl.DataCase, async: false

  alias Alnasl.{AccessPin, DoorGuard, PinRequest, Settings}

  @moduletag :tmp_dir
  @moduletag :capture_log

  defp request(dir, content), do: File.write!(Path.join(dir, "pin-request"), content)
  defp request?(dir), do: File.exists?(Path.join(dir, "pin-request"))

  defp on_disk(dir) do
    {:ok, pin} = AccessPin.read(dir)
    pin
  end

  defp windows?, do: match?({:win32, _}, :os.type())

  describe "generation" do
    test "the first start makes six random digits, private, and a restart keeps them", %{
      tmp_dir: dir
    } do
      assert AccessPin.boot(dir) == :made
      pin = on_disk(dir)
      assert pin =~ ~r/\A\d{6}\z/
      assert File.read!(AccessPin.path(dir)) == pin <> "\n"
      refute File.exists?(AccessPin.path(dir) <> ".new")

      unless windows?() do
        assert {:ok, %File.Stat{mode: mode}} = File.stat(AccessPin.path(dir))
        assert Bitwise.band(mode, 0o777) == 0o600
      end

      AccessPin.forget(dir)
      assert AccessPin.boot(dir) == :kept
      assert AccessPin.current(dir) == pin
    end

    test "random PINs are six digits and not all the same" do
      pins = for _ <- 1..50, do: AccessPin.random()
      assert Enum.all?(pins, &(&1 =~ ~r/\A\d{6}\z/))
      assert length(Enum.uniq(pins)) > 40
    end

    test "a file that went missing is made again: there is always a PIN", %{tmp_dir: dir} do
      AccessPin.boot(dir)
      File.rm!(AccessPin.path(dir))
      AccessPin.forget(dir)
      assert AccessPin.current(dir) =~ ~r/\A\d{6}\z/
      assert File.exists?(AccessPin.path(dir))
    end

    test "an old hash is retired, a new PIN made, and Setup told once", %{tmp_dir: dir} do
      Settings.put("pin", %{"salt" => "ab", "hash" => "cd", "long" => true})

      assert AccessPin.boot(dir) == :replaced_legacy
      assert Settings.get("pin") == nil
      assert on_disk(dir) =~ ~r/\A\d{6}\z/
      assert AccessPin.notice?()

      AccessPin.notice_seen()
      refute AccessPin.notice?()
    end
  end

  describe "the rules" do
    test "6 to 64 characters, no space at the ends, nothing invisible" do
      assert AccessPin.validate("12345") == {:error, :too_short}
      assert AccessPin.validate("") == {:error, :too_short}
      assert AccessPin.validate(String.duplicate("x", 65)) == {:error, :too_long}
      assert AccessPin.validate(String.duplicate("x", 64)) == :ok
      assert AccessPin.validate("123456") == :ok
      assert AccessPin.validate("é ü ß !?") == :ok
      assert AccessPin.validate(" 123456") == {:error, :edge_space}
      assert AccessPin.validate("123456 ") == {:error, :edge_space}
      assert AccessPin.validate("123\t456") == {:error, :invisible}
      assert AccessPin.validate("123\x7f456") == {:error, :invisible}
      assert AccessPin.validate("123\u0085456") == {:error, :invisible}
      assert AccessPin.validate(<<0xFF, "23456">>) == {:error, :invisible}
      assert AccessPin.validate(nil) == {:error, :too_short}
    end

    test "a refused PIN leaves the one there was", %{tmp_dir: dir} do
      AccessPin.boot(dir)
      pin = on_disk(dir)
      assert {:error, :too_short} = AccessPin.set("1", dir)
      assert AccessPin.current(dir) == pin
      assert on_disk(dir) == pin
    end

    test "there is no removing it: no function, and empty is not none", %{tmp_dir: dir} do
      AccessPin.boot(dir)
      refute function_exported?(AccessPin, :remove, 0)
      refute function_exported?(AccessPin, :remove, 1)
      assert {:error, :too_short} = AccessPin.set("", dir)
      assert {:error, :too_short} = AccessPin.set(nil, dir)
      assert AccessPin.valid?(on_disk(dir), dir)
      refute AccessPin.valid?("", dir)
      refute AccessPin.valid?(nil, dir)
    end
  end

  describe "the request file" do
    test "set: the PIN is applied and the file gone", %{tmp_dir: dir} do
      AccessPin.boot(dir)
      request(dir, "set\nhall pin 7\n")
      assert PinRequest.consume(dir) == :set
      refute request?(dir)
      assert on_disk(dir) == "hall pin 7"
      assert AccessPin.current(dir) == "hall pin 7"
    end

    test "set at the first start: the box's PIN, not a random one", %{tmp_dir: dir} do
      request(dir, "set\r\n246810\r\n")
      assert AccessPin.boot(dir) == :kept
      assert on_disk(dir) == "246810"
    end

    test "new: six fresh digits", %{tmp_dir: dir} do
      AccessPin.set("old-pin-1", dir)
      request(dir, "new\n")
      assert PinRequest.consume(dir) == :new
      refute request?(dir)
      assert on_disk(dir) =~ ~r/\A\d{6}\z/
    end

    test "remove, garbage and a bad PIN are refused, the PIN kept, the file gone", %{
      tmp_dir: dir
    } do
      AccessPin.set("kept-pin", dir)

      for {content, reason} <- [
            {"remove\n", :unknown_command},
            {"remove", :unknown_command},
            {"", :unknown_command},
            {"hello\nworld\n", :unknown_command},
            {"set\n123\n", :too_short},
            {"set\n 123456\n", :edge_space},
            {"set\n123456\nmore\n", :invisible},
            {"new\n123456\n", :unreadable}
          ] do
        request(dir, content)
        assert PinRequest.consume(dir) == {:refused, reason}, inspect(content)
        refute request?(dir)
        assert on_disk(dir) == "kept-pin"
      end
    end

    test "no file, nothing done", %{tmp_dir: dir} do
      assert PinRequest.consume(dir) == :none
    end

    test "a symlink is not read: deleted and refused", %{tmp_dir: dir} do
      AccessPin.set("kept-pin", dir)
      target = Path.join(dir, "elsewhere")
      File.write!(target, "set\n999999\n")

      case File.ln_s(target, Path.join(dir, "pin-request")) do
        :ok ->
          assert PinRequest.consume(dir) == {:refused, :not_a_plain_file}
          refute request?(dir)
          assert File.read!(target) == "set\n999999\n"
          assert on_disk(dir) == "kept-pin"

        {:error, _no_symlinks_here} ->
          # Windows without the right to make symlinks.
          :ok
      end
    end

    test "a symlink at access-pin is neither read nor written through", %{tmp_dir: dir} do
      target = Path.join(dir, "victim")
      File.write!(target, "123456\n")

      case File.ln_s(target, AccessPin.path(dir)) do
        :ok ->
          assert AccessPin.read(dir) == :none
          assert :ok = AccessPin.set("654321", dir)
          assert File.read!(target) == "123456\n"
          assert {:ok, %File.Stat{type: :regular}} = File.lstat(AccessPin.path(dir))
          assert on_disk(dir) == "654321"

        {:error, _no_symlinks_here} ->
          :ok
      end
    end
  end

  describe "the lockout" do
    setup do
      DoorGuard.reset()
      on_exit(&DoorGuard.reset/0)
    end

    test "five free guesses, then 5, 10, 20 seconds, capped at a quarter of an hour" do
      ip = {198, 51, 100, 9}
      for _ <- 1..4, do: assert(DoorGuard.claim(ip, 0) == :ok)
      assert DoorGuard.claim(ip, 0) == :ok
      # The fifth failure: wait five seconds, the right PIN included.
      assert DoorGuard.claim(ip, 0) == {:wait, 5}
      assert DoorGuard.claim(ip, 5) == :ok
      assert DoorGuard.claim(ip, 5) == {:wait, 10}
      assert DoorGuard.claim(ip, 15) == :ok
      assert DoorGuard.claim(ip, 15) == {:wait, 20}

      for _ <- 8..20, do: DoorGuard.failed(ip, 35)
      assert DoorGuard.check(ip, 35) == {:wait, 900}
    end

    test "a right guess takes its claim back and clears the count" do
      ip = {198, 51, 100, 10}
      for _ <- 1..4, do: DoorGuard.claim(ip, 0)
      assert DoorGuard.claim(ip, 0) == :ok
      DoorGuard.succeeded(ip)
      assert DoorGuard.check(ip, 0) == :ok
      assert DoorGuard.claim(ip, 0) == :ok
    end

    test "forty failures a minute across the box, then every address that has failed waits" do
      for n <- 1..40, do: assert(DoorGuard.claim({10, 1, 0, n}, 0) == :ok)
      assert {:wait, 60} = DoorGuard.claim({10, 1, 0, 1}, 0)
      assert DoorGuard.claim({10, 1, 0, 1}, 61) == :ok
    end

    test "under the box-wide cap an address that has not failed still gets two tries" do
      for n <- 1..40, do: assert(DoorGuard.claim({10, 1, 0, n}, 0) == :ok)
      fresh = {10, 9, 9, 9}

      assert DoorGuard.check(fresh, 0) == :ok
      assert DoorGuard.claim(fresh, 0) == :ok
      assert DoorGuard.claim(fresh, 0) == :ok
      assert {:wait, 60} = DoorGuard.claim(fresh, 0)
      assert {:wait, 60} = DoorGuard.check(fresh, 0)

      # A right PIN on the first try goes in, and the grace is not spent twice.
      other = {10, 9, 9, 10}
      assert DoorGuard.claim(other, 0) == :ok
      DoorGuard.succeeded(other)
      assert DoorGuard.claim(other, 0) == :ok
      assert DoorGuard.claim(other, 0) == :ok
      assert {:wait, 60} = DoorGuard.claim(other, 0)
    end

    test "the grace is for a device that has not failed: failing first spends it" do
      ip = {10, 9, 8, 7}
      assert DoorGuard.claim(ip, 0) == :ok
      for n <- 1..40, do: DoorGuard.claim({10, 1, 0, n}, 0)
      assert {:wait, 60} = DoorGuard.claim(ip, 0)
    end

    test "a burst cannot outrun the count" do
      ip = {198, 51, 100, 11}

      results =
        1..50
        |> Task.async_stream(fn _ -> DoorGuard.claim(ip, 0) end, max_concurrency: 50)
        |> Enum.map(fn {:ok, r} -> r end)

      assert Enum.count(results, &(&1 == :ok)) == 5
    end
  end
end
