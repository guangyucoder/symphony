defmodule SymphonyElixir.LedgerTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Ledger

  setup do
    workspace = Path.join(System.tmp_dir!(), "ledger_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(workspace, ".symphony"))
    on_exit(fn -> File.rm_rf!(workspace) end)
    %{workspace: workspace}
  end

  describe "append/3 and read/1" do
    test "appends and reads events", %{workspace: ws} do
      :ok = Ledger.append(ws, :unit_started, %{"kind" => "bootstrap"})
      :ok = Ledger.append(ws, :unit_accepted, %{"kind" => "bootstrap"})

      {:ok, entries} = Ledger.read(ws)
      assert length(entries) == 2
      assert Enum.at(entries, 0)["event"] == "unit_started"
      assert Enum.at(entries, 1)["event"] == "unit_accepted"
    end

    test "reads empty when file doesn't exist", %{workspace: ws} do
      {:ok, entries} = Ledger.read(ws)
      assert entries == []
    end

    test "entries have timestamps", %{workspace: ws} do
      :ok = Ledger.append(ws, :test_event, %{})
      {:ok, [entry]} = Ledger.read(ws)
      assert is_binary(entry["ts"])
    end

    test "skips corrupt lines", %{workspace: ws} do
      path = Path.join([ws, ".symphony", "ledger.jsonl"])
      File.write!(path, ~s|{"ts":"t1","event":"good","payload":{}}\nthis is garbage\n{"ts":"t2","event":"also_good","payload":{}}\n|)

      {:ok, entries} = Ledger.read(ws)
      assert length(entries) == 2
      assert Enum.at(entries, 0)["event"] == "good"
      assert Enum.at(entries, 1)["event"] == "also_good"
    end
  end

  describe "convenience helpers" do
    test "unit_started/2", %{workspace: ws} do
      unit = %{"kind" => "plan", "subtask_id" => nil}
      :ok = Ledger.unit_started(ws, unit)
      {:ok, [entry]} = Ledger.read(ws)
      assert entry["event"] == "unit_started"
      assert entry["payload"]["kind"] == "plan"
    end

    test "unit_accepted/3", %{workspace: ws} do
      unit = %{"kind" => "implement_subtask", "subtask_id" => "plan-1"}
      :ok = Ledger.unit_accepted(ws, unit, %{"commit" => "abc123"})
      {:ok, [entry]} = Ledger.read(ws)
      assert entry["event"] == "unit_accepted"
      assert entry["payload"]["subtask_id"] == "plan-1"
      assert entry["payload"]["commit"] == "abc123"
    end

    test "verify_passed/2", %{workspace: ws} do
      :ok = Ledger.verify_passed(ws, "def456")
      {:ok, [entry]} = Ledger.read(ws)
      assert entry["event"] == "verify_passed"
      assert entry["payload"]["sha"] == "def456"
    end
  end
end
