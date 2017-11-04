defmodule CountingAgent do
  def start_link(initial) do
    Agent.start_link fn -> initial end
  end

  def inc(agent) do
    Agent.update(agent, fn counter -> counter + 1 end)
  end

  def dec(agent) do
    Agent.update(agent, fn counter -> counter - 1 end)
  end

  def get(agent) do
    Agent.get(agent, fn counter -> counter end)
  end
end

defmodule SideEffectAgent do
  def start_link do
    Agent.start_link fn -> [] end
  end

  def create_side_effect(agent, effect) do
    Agent.update(agent, fn effects ->
      if effect not in effects do
        [effect | effects]
      else
        raise "Trying to re-apply stale effect"
      end
    end)
  end

  def delete_side_effect(agent, effect) do
    Agent.update(agent, fn effects ->
      if effect in effects do
        List.delete(effects, effect)
      else
        raise "Effect not found"
      end
    end)
  end

  def side_effects(agent) do
    Agent.get(agent, fn list -> Enum.reverse(list) end)
  end
end

defmodule SageTest do
  use ExUnit.Case
  import Sage
  doctest Sage

  test "applies transactions" do
    {:ok, agent} = SideEffectAgent.start_link()

    result =
      new()
      |> run(:step1, &tx_ok(&1, &2, agent, :t1), &cmp_ok(&1, &2, &3, agent))
      |> run(:step2, &tx_ok(&1, &2, agent, :t2), &cmp_ok(&1, &2, &3, agent))
      |> run(:step3, &tx_ok(&1, &2, agent, :t3), &cmp_ok(&1, &2, &3, agent))
      |> finally(fn :ok -> :ok end)
      |> execute([a: :b])

    assert SideEffectAgent.side_effects(agent) == [:t1, :t2, :t3]
    assert result == {:ok, :t3, %{step1: :t1, step2: :t2, step3: :t3}}
  end

  test "wraps sagas in anonymous function" do
    {:ok, agent} = SideEffectAgent.start_link()

    function =
      new()
      |> run(:step1, &tx_ok(&1, &2, agent, :t1), &cmp_ok(&1, &2, &3, agent))
      |> run(:step2, &tx_ok(&1, &2, agent, :t2), &cmp_ok(&1, &2, &3, agent))
      |> run(:step3, &tx_ok(&1, &2, agent, :t3), &cmp_ok(&1, &2, &3, agent))
      |> finally(fn :ok -> :ok end)
      |> to_function([a: :b])

    assert SideEffectAgent.side_effects(agent) == []

    result = function.()
    assert SideEffectAgent.side_effects(agent) == [:t1, :t2, :t3]
    assert result == {:ok, :t3, %{step1: :t1, step2: :t2, step3: :t3}}
  end

  test "finalizes transactions" do
    {:ok, agent} = SideEffectAgent.start_link()
    test_pid = self()

    result =
      new()
      |> run(:step1, &tx_ok(&1, &2, agent, :t1), &cmp_ok(&1, &2, &3, agent))
      |> finally(&send(test_pid, &1))
      |> finally({__MODULE__, :do_send, [test_pid]})
      |> execute([a: :b])

    assert_receive :ok
    assert_receive :ok

    assert SideEffectAgent.side_effects(agent) == [:t1]
    assert result == {:ok, :t1, %{step1: :t1}}
  end

  def do_send(msg, pid), do: send(pid, msg)

  test "accepts side-effects free transactions" do
    {:ok, agent} = SideEffectAgent.start_link()

    result =
      new()
      |> run(:step1, &tx_ok(&1, &2, agent, :t1))
      |> execute([a: :b])

    assert SideEffectAgent.side_effects(agent) == [:t1]
    assert result == {:ok, :t1, %{step1: :t1}}
  end

  test "raises on duplicated names" do
    {:ok, agent} = SideEffectAgent.start_link()

    assert_raise RuntimeError, ~r":step1 is already a member of the Sage:", fn ->
      new()
      |> run(:step1, &tx_ok(&1, &2, agent, :t1))
      |> run(:step1, &tx_ok(&1, &2, agent, :t1))
    end
  end

  test "accepts mfa tuples" do
    {:ok, agent} = SideEffectAgent.start_link()

    result =
      new()
      |> run(:step1, {__MODULE__, :tx_err, [agent, :t1]}, {__MODULE__, :cmp_ok, [agent]})
      |> execute([a: :b])

    assert SideEffectAgent.side_effects(agent) == []
    assert result == {:error, :t1}
  end

  test "compensates errors on last step" do
    {:ok, agent} = SideEffectAgent.start_link()

    result =
      new()
      |> run(:step1, &tx_ok(&1, &2, agent, :t1), &cmp_ok(&1, &2, &3, agent))
      |> run(:step2, &tx_ok(&1, &2, agent, :t2), &cmp_ok(&1, &2, &3, agent))
      |> run(:step3, &tx_err(&1, &2, agent, :t3), &cmp_ok(&1, &2, &3, agent))
      |> finally(fn :error -> :results_are_ignored_mmkay end)
      |> execute([a: :b])

    assert SideEffectAgent.side_effects(agent) == []
    assert result == {:error, :t3}
  end

  test "compensates errors in the middle" do
    {:ok, agent} = SideEffectAgent.start_link()

    result =
      new()
      |> run(:step1, &tx_ok(&1, &2, agent, :t1), &cmp_ok(&1, &2, &3, agent))
      |> run(:step2, &tx_err(&1, &2, agent, :t2), &cmp_ok(&1, &2, &3, agent))
      |> run(:step3, &tx_ok(&1, &2, agent, :t3), &cmp_ok(&1, &2, &3, agent))
      |> execute([a: :b])

    assert SideEffectAgent.side_effects(agent) == []
    assert result == {:error, :t2}
  end

  test "reties transactions" do
    {:ok, agent} = SideEffectAgent.start_link()
    {:ok, counter} = CountingAgent.start_link(3)

    result =
      new()
      |> run(:step1, &tx_ok(&1, &2, agent, :t1), &cmp_retry(&1, &2, &3, agent))
      |> run(:step2, &tx_ok(&1, &2, agent, :t2), &cmp_ok(&1, &2, &3, agent))
      |> run(:step3, &tx_err_n_times(&1, &2, agent, counter, :t3), &cmp_ok(&1, &2, &3, agent))
      |> execute([a: :b])

    assert SideEffectAgent.side_effects(agent) == [:t1, :t2, :t3]
    assert result == {:ok, :t3, %{step1: :t1, step2: :t2, step3: :t3}}
  end

  test "reties count" do
    {:ok, agent} = SideEffectAgent.start_link()

    result =
      new()
      |> run(:step1, &tx_ok(&1, &2, agent, :t1), &cmp_ok(&1, &2, &3, agent))
      |> run(:step2, &tx_ok(&1, &2, agent, :t2), &cmp_retry(&1, &2, &3, agent, 3))
      |> run(:step3, &tx_err(&1, &2, agent, :t3), &cmp_ok(&1, &2, &3, agent))
      |> execute([a: :b])

    assert SideEffectAgent.side_effects(agent) == []
    assert result == {:error, :t3}
  end

  test "ignores retries on compensation abort" do
    {:ok, agent} = SideEffectAgent.start_link()

    result =
      new()
      |> run(:step1, &tx_ok(&1, &2, agent, :t1), &cmp_retry(&1, &2, &3, agent))
      |> run(:step2, &tx_ok(&1, &2, agent, :t2), &cmp_ok(&1, &2, &3, agent))
      |> run(:step3, &tx_err(&1, &2, agent, :t3), &cmp_abort(&1, &2, &3, agent))
      |> execute([a: :b])

    assert SideEffectAgent.side_effects(agent) == []
    assert result == {:error, :t3}
  end

  test "ignores retries on transactions abort" do
    {:ok, agent} = SideEffectAgent.start_link()

    result =
      new()
      |> run(:step1, &tx_ok(&1, &2, agent, :t1), &cmp_retry(&1, &2, &3, agent, 1000))
      |> run(:step2, &tx_ok(&1, &2, agent, :t2), &cmp_ok(&1, &2, &3, agent))
      |> run(:step3, &tx_abort(&1, &2, agent, :t3), &cmp_ok(&1, &2, &3, agent))
      |> execute([a: :b])

    assert SideEffectAgent.side_effects(agent) == []
    assert result == {:error, :t3}
  end

  test "circuit breaker" do
    {:ok, agent} = SideEffectAgent.start_link()

    result =
      new()
      |> run(:step1, &tx_ok(&1, &2, agent, :t1), &cmp_ok(&1, &2, &3, agent))
      |> run(:step2, &tx_err(&1, &2, agent, :t2), &cmp_continue(&1, &2, &3, agent))
      |> run(:step3, &tx_ok(&1, &2, agent, :t3), &cmp_ok(&1, &2, &3, agent))
      |> execute([a: :b])

    assert SideEffectAgent.side_effects(agent) == [:t1, :t3]
    assert result == {:ok, :t3, %{step1: :t1, step2: :fallback_return, step3: :t3}}
  end

  test "circuit breaker raises when other stage is failed" do
    {:ok, agent} = SideEffectAgent.start_link()

    assert_raise RuntimeError, "Circuit breaking is only allowed for continuing compensated transaction", fn ->
      new()
      |> run(:step1, &tx_ok(&1, &2, agent, :t1), &cmp_ok(&1, &2, &3, agent))
      |> run(:step2, &tx_ok(&1, &2, agent, :t2), &cmp_continue(&1, &2, &3, agent))
      |> run(:step3, &tx_err(&1, &2, agent, :t3), &cmp_ok(&1, &2, &3, agent))
      |> execute([a: :b])
    end
  end

  test "async txs" do
    {:ok, agent} = SideEffectAgent.start_link()

    result =
      new()
      |> run_async(:step1, &tx_ok(&1, &2, agent, :t1), &cmp_ok(&1, &2, &3, agent))
      |> run_async(:step2, &tx_ok(&1, &2, agent, :t2), &cmp_ok(&1, &2, &3, agent))
      |> run(:step3, &tx_ok(&1, &2, agent, :t3), &cmp_ok(&1, &2, &3, agent))
      |> execute([a: :b])

    assert SideEffectAgent.side_effects(agent) == [:t1, :t2, :t3]
    assert result == {:ok, :t3, %{step1: :t1, step2: :t2, step3: :t3}}
  end

  test "end with async txs" do
    {:ok, agent} = SideEffectAgent.start_link()

    result =
      new()
      |> run(:step1, &tx_ok(&1, &2, agent, :t1), &cmp_ok(&1, &2, &3, agent))
      |> run_async(:step2, &tx_ok(&1, &2, agent, :t2), &cmp_ok(&1, &2, &3, agent))
      |> run_async(:step3, &tx_ok(&1, &2, agent, :t3), &cmp_ok(&1, &2, &3, agent))
      |> execute([a: :b])

    assert SideEffectAgent.side_effects(agent) == [:t1, :t2, :t3]
    assert result == {:ok, :t3, %{step1: :t1, step2: :t2, step3: :t3}}
  end

  describe "compensates errors async txs" do
    test "when error occurrences is after async operation" do
      {:ok, agent} = SideEffectAgent.start_link()

      result =
        new()
        |> run_async(:step1, &tx_ok(&1, &2, agent, :t1), &cmp_ok(&1, &2, &3, agent))
        |> run_async(:step2, &tx_ok(&1, &2, agent, :t2), &cmp_ok(&1, &2, &3, agent))
        |> run(:step3, &tx_err(&1, &2, agent, :t3), &cmp_ok(&1, &2, &3, agent))
        |> execute([a: :b])

      assert SideEffectAgent.side_effects(agent) == []
      assert result == {:error, :t3}
    end

    test "when error occurrences is on of async operations" do
      {:ok, agent} = SideEffectAgent.start_link()

      result =
        new()
        |> run_async(:step1, &tx_ok(&1, &2, agent, :t1), &cmp_ok(&1, &2, &3, agent))
        |> run_async(:step2, &tx_err(&1, &2, agent, :t2), &cmp_ok(&1, &2, &3, agent))
        |> run_async(:step3, &tx_ok(&1, &2, agent, :t3), &cmp_ok(&1, &2, &3, agent))
        |> execute([a: :b])

      assert SideEffectAgent.side_effects(agent) == []
      assert result == {:error, :t2}
    end

    test "with retry and abort" do
      {:ok, agent} = SideEffectAgent.start_link()
      test_pid = self()

      result =
        new()
        |> run_async(:step1, &tx_ok(&1, &2, agent, :t1), &cmp_retry(&1, &2, &3, agent))
        |> run_async(:step2, &tx_ok(&1, &2, agent, :t2), &cmp_abort(&1, &2, &3, agent))
        |> run_async(:step3, &tx_err(&1, &2, agent, :t3), &cmp_retry(&1, &2, &3, agent))
        |> finally(fn :error -> send(test_pid, {:finally, :error}) end)
        |> execute([a: :b])

      assert_receive {:finally, :error}
      assert SideEffectAgent.side_effects(agent) == []
      assert result == {:error, :t3}
    end
  end

  describe "error handling" do
    test "raise in transaction" do
      {:ok, agent} = SideEffectAgent.start_link()
      test_pid = self()

      error_callback =
        fn agent_pid, tid, _effects_so_far, _opts ->
          SideEffectAgent.create_side_effect(agent_pid, tid)
          raise RuntimeError, "Error in transaction #{inspect(tid)}"
        end

      assert_raise RuntimeError, "Error in transaction :t3", fn ->
        new()
        |> run(:step1, &tx_ok(&1, &2, agent, :t1), &cmp_retry(&1, &2, &3, agent))
        |> run(:step2, &tx_ok(&1, &2, agent, :t2), &cmp_ok(&1, &2, &3, agent))
        |> run(:step3, &error_callback.(agent, :t3, &1, &2), &cmp_ok(&1, &2, &3, agent, :t3))
        |> finally(fn :error -> send(test_pid, {:finally, :error}) end)
        |> execute([a: :b])
      end

      assert_receive {:finally, :error}
      assert SideEffectAgent.side_effects(agent) == []
    end

    test "exit in transaction" do
      {:ok, agent} = SideEffectAgent.start_link()
      test_pid = self()

      error_callback =
        fn agent_pid, tid, _effects_so_far, _opts ->
          SideEffectAgent.create_side_effect(agent_pid, tid)
          exit "Error in transaction #{inspect(tid)}"
        end

      assert catch_exit(
        new()
        |> run(:step1, &tx_ok(&1, &2, agent, :t1), &cmp_retry(&1, &2, &3, agent))
        |> run(:step2, &tx_ok(&1, &2, agent, :t2), &cmp_ok(&1, &2, &3, agent))
        |> run(:step3, &error_callback.(agent, :t3, &1, &2), &cmp_ok(&1, &2, &3, agent, :t3))
        |> finally(fn :error -> send(test_pid, {:finally, :error}) end)
        |> execute([a: :b])
      ) == "Error in transaction :t3"

      assert_receive {:finally, :error}
      assert SideEffectAgent.side_effects(agent) == []
    end

    test "unexpected return transaction" do
      {:ok, agent} = SideEffectAgent.start_link()
      test_pid = self()

      error_callback =
        fn agent_pid, tid, _effects_so_far, _opts ->
          SideEffectAgent.create_side_effect(agent_pid, tid)
          {:bad_returns, :are_bad_mmkay}
        end

      message = ~r"""
      ^unexpected return from transaction function .*,
      expected it to be {:ok, effect}, {:error, reason} or {:abort, reason}, got:

        {:bad_returns, :are_bad_mmkay}$
      """

      assert_raise RuntimeError, message, fn ->
        new()
        |> run(:step1, &tx_ok(&1, &2, agent, :t1), &cmp_retry(&1, &2, &3, agent))
        |> run(:step2, &tx_ok(&1, &2, agent, :t2), &cmp_ok(&1, &2, &3, agent))
        |> run(:step3, &error_callback.(agent, :t3, &1, &2), &cmp_ok(&1, &2, &3, agent, :t3))
        |> finally(fn :error -> send(test_pid, {:finally, :error}) end)
        |> execute([a: :b])
      end

      assert_receive {:finally, :error}
      assert SideEffectAgent.side_effects(agent) == []
    end

    test "timeout in async transaction" do
      {:ok, agent} = SideEffectAgent.start_link()
      test_pid = self()

      error_callback =
        fn agent_pid, tid, _effects_so_far, _opts ->
          SideEffectAgent.create_side_effect(agent_pid, tid)
          :timer.sleep(100)
          {:ok, :slowpoke_return}
        end

      assert_raise RuntimeError, "asynchronous transaction did not return within the timeout 10", fn ->
        new()
        |> run(:step1, &tx_ok(&1, &2, agent, :t1), &cmp_retry(&1, &2, &3, agent))
        |> run(:step2, &tx_ok(&1, &2, agent, :t2), &cmp_ok(&1, &2, &3, agent))
        |> run_async(:step3, &error_callback.(agent, :t3, &1, &2), &cmp_ok(&1, &2, &3, agent, :t3), timeout: 10)
        |> finally(fn :error -> send(test_pid, {:finally, :error}) end)
        |> execute([a: :b])
      end

      assert_receive {:finally, :error}
      assert SideEffectAgent.side_effects(agent) == []
    end

    test "raise in async transaction" do
      {:ok, agent} = SideEffectAgent.start_link()
      test_pid = self()

      error_callback =
        fn agent_pid, tid, _effects_so_far, _opts ->
          SideEffectAgent.create_side_effect(agent_pid, tid)
          raise RuntimeError, "Error in transaction #{inspect(tid)}"
        end

      assert_raise RuntimeError, "Error in transaction :t3", fn ->
        new()
        |> run(:step1, &tx_ok(&1, &2, agent, :t1), &cmp_retry(&1, &2, &3, agent))
        |> run(:step2, &tx_ok(&1, &2, agent, :t2), &cmp_ok(&1, &2, &3, agent))
        |> run_async(:step3, &error_callback.(agent, :t3, &1, &2), &cmp_ok(&1, &2, &3, agent, :t3))
        |> finally(fn :error -> send(test_pid, {:finally, :error}) end)
        |> execute([a: :b])
      end

      assert_receive {:finally, :error}
      assert SideEffectAgent.side_effects(agent) == []
    end

    test "exit in async transaction" do
      {:ok, agent} = SideEffectAgent.start_link()
      test_pid = self()

      error_callback =
        fn agent_pid, tid, _effects_so_far, _opts ->
          SideEffectAgent.create_side_effect(agent_pid, tid)
          exit "Error in transaction #{inspect(tid)}"
        end

      assert catch_exit(
        new()
        |> run(:step1, &tx_ok(&1, &2, agent, :t1), &cmp_retry(&1, &2, &3, agent))
        |> run(:step2, &tx_ok(&1, &2, agent, :t2), &cmp_ok(&1, &2, &3, agent))
        |> run_async(:step3, &error_callback.(agent, :t3, &1, &2), &cmp_ok(&1, &2, &3, agent, :t3))
        |> finally(fn :error -> send(test_pid, {:finally, :error}) end)
        |> execute([a: :b])
      ) == "Error in transaction :t3"

      assert_receive {:finally, :error}
      assert SideEffectAgent.side_effects(agent) == []
    end

    test "unexpected return async transaction" do
      {:ok, agent} = SideEffectAgent.start_link()
      test_pid = self()

      error_callback =
        fn agent_pid, tid, _effects_so_far, _opts ->
          SideEffectAgent.create_side_effect(agent_pid, tid)
          {:bad_returns, :are_bad_mmkay}
        end

      message = ~r"""
      ^unexpected return from transaction function .*,
      expected it to be {:ok, effect}, {:error, reason} or {:abort, reason}, got:

        {:bad_returns, :are_bad_mmkay}$
      """

      assert_raise RuntimeError, message, fn ->
        new()
        |> run(:step1, &tx_ok(&1, &2, agent, :t1), &cmp_retry(&1, &2, &3, agent))
        |> run(:step2, &tx_ok(&1, &2, agent, :t2), &cmp_ok(&1, &2, &3, agent))
        |> run_async(:step3, &error_callback.(agent, :t3, &1, &2), &cmp_ok(&1, &2, &3, agent, :t3))
        |> finally(fn :error -> send(test_pid, {:finally, :error}) end)
        |> execute([a: :b])
      end

      assert_receive {:finally, :error}
      assert SideEffectAgent.side_effects(agent) == []
    end

    test "raise, exit or unexpected return in compensation" do
      {:ok, agent} = SideEffectAgent.start_link()
      test_pid = self()

      error_callback =
        fn agent_pid, effect_to_compensate, {name, _reason}, _opts ->
          SideEffectAgent.delete_side_effect(agent_pid, effect_to_compensate)
          raise RuntimeError, "Error in transaction #{inspect(name)}"
        end

      assert_raise RuntimeError, "Error in transaction :step3", fn ->
        new()
        |> run(:step1, &tx_ok(&1, &2, agent, :t1), &cmp_retry(&1, &2, &3, agent))
        |> run(:step2, &tx_ok(&1, &2, agent, :t2), &error_callback.(agent, &1, &2, &3))
        |> run_async(:step3, &tx_err(&1, &2, agent, :t3), &cmp_ok(&1, &2, &3, agent, :t3))
        |> finally(fn :error -> send(test_pid, {:finally, :error}) end)
        |> execute([a: :b])
      end

      refute_receive {:finally, :error}
      assert SideEffectAgent.side_effects(agent) == [:t1]
    end
  end

  def tx_ok(_effects_so_far, _opts, agent_pid, tid) do
    SideEffectAgent.create_side_effect(agent_pid, tid)
    {:ok, tid}
  end

  def tx_abort(_effects_so_far, _opts, agent_pid, tid) do
    SideEffectAgent.create_side_effect(agent_pid, tid)
    {:abort, tid}
  end

  def tx_err(_effects_so_far, _opts, agent_pid, tid) do
    SideEffectAgent.create_side_effect(agent_pid, tid)
    {:error, tid}
  end

  def tx_err_n_times(effects_so_far, opts, agent_pid, counter_pid, tid) do
    if CountingAgent.get(counter_pid) > 0 do
      SideEffectAgent.create_side_effect(agent_pid, tid)
      CountingAgent.dec(counter_pid)
      {:error, tid}
    else
      tx_ok(effects_so_far, opts, agent_pid, tid)
    end
  end

  def cmp_ok(effect_to_compensate, {_name, _reason}, _opts, agent_pid, effect_override \\ nil) do
    SideEffectAgent.delete_side_effect(agent_pid, effect_override || effect_to_compensate)
    :ok
  end

  # I am compensated by transaction, let's retry with this data from my tx
  def cmp_retry(effect_to_compensate, {_name, _reason}, _opts, agent_pid, limit \\ 3) do
    SideEffectAgent.delete_side_effect(agent_pid, effect_to_compensate)
    {:retry, [retry_limit: limit]}
  end

  # I am compensated transaction and want to force backwards recovery on all steps
  def cmp_abort(effect_to_compensate, {_name, _reason}, _opts, agent_pid) do
    SideEffectAgent.delete_side_effect(agent_pid, effect_to_compensate)
    :abort
  end

  # I am the Circuit Breaker and I know how live wit this error
  def cmp_continue(effect_to_compensate, {_name, _reason}, _opts, agent_pid) do
    SideEffectAgent.delete_side_effect(agent_pid, effect_to_compensate)
    {:continue, :fallback_return}
  end
end