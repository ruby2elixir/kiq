defmodule Kiq.Reporter.RetryerTest do
  use Kiq.Case, async: true

  alias Kiq.{EchoClient, Job}
  alias Kiq.Reporter.Retryer, as: Reporter

  defmodule FakeProducer do
    use GenStage

    def start_link(opts) do
      GenStage.start_link(__MODULE__, opts)
    end

    def init(events: events) do
      {:producer, events}
    end

    def handle_demand(_demand, events) do
      {:noreply, events, []}
    end
  end

  defp emit_event(event) do
    {:ok, cli} = start_supervised({EchoClient, test_pid: self()})
    {:ok, pro} = start_supervised({FakeProducer, events: [event]})
    {:ok, con} = start_supervised({Reporter, client: cli})

    GenStage.sync_subscribe(con, to: pro)

    Process.sleep(10)

    :ok = stop_supervised(Reporter)
    :ok = stop_supervised(FakeProducer)
    :ok = stop_supervised(EchoClient)
  end

  test "job start is safely ignored" do
    assert :ok = emit_event({:started, job()})
  end

  test "successful jobs are pruned from the backup queue" do
    job = job()

    :ok = emit_event({:success, job, []})

    assert_receive {:remove_backup, ^job}
  end

  test "failed jobs are pushed into the retry set" do
    error = %RuntimeError{message: "bad stuff happened"}

    :ok = emit_event({:failure, job(retry: true, retry_count: 0), error})

    receive do
      {:enqueue_at, %Job{} = job, "retry"} ->
        assert job.retry_count == 1
        assert job.error_class == "RuntimeError"
        assert job.error_message == "bad stuff happened"

      after
        100 ->
          flunk "No :retry message was ever received"
    end
  end

  test "jobs are not enqueued when retries are exhausted" do
    error = %RuntimeError{message: "bad stuff happened"}

    :ok = emit_event({:failure, job(retry: true, retry_count: 25), error})

    refute_receive {:enqueue_at, %Job{}, "retry"}
  end
end
