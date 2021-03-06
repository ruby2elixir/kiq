defmodule Kiq do
  @moduledoc """
  Kiq is a robust and extensible job processing queue that aims for
  compatibility with Sidekiq Enterprise.

  Job queuing, processing and reporting are all built on GenStage. That means
  maximum parallelism with the safety of backpressure as jobs are processed.

  ## Usage

  Kiq isn't an application that must be started. Similarly to Ecto, you define
  one or more Kiq modules within your application. This allows multiple
  supervision trees with entirely different configurations.

  Define a Kiq module for your application:

      defmodule MyApp.Kiq do
        use Kiq, queues: [default: 25, events: 50]
      end

  Include the module in your application's supervision tree:

      defmodule MyApp.Application do
        @moduledoc false

        use Application

        alias MyApp.{Endpoint, Kiq, Repo}

        def start(_type, _args) do
          children = [
            {Repo, []},
            {Endpoint, []},
            {Kiq, []}
          ]

          Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor)
        end
      end

  ## Configuration

  Kiq is used to start one or more supervision trees in your application. That
  means there isn't a central Kiq "app" to configure, instead each supervision
  tree may be configured independently.

  Configuration options pass through a couple of locations, accumulating
  overrides until finally passing through the `init/2` callback. Options are
  accumulated in this order:

  1. Options passed into via the `use` macro. These should be constant compile
     time options, i.e. `extra_reporters`.
  2. Options passed to `start_link/1` by the application's supervision tree.
     These should also be values suitable for compile time.
  3. Injected by the `init/2` callback inside your application's Kiq instance.
     This is where runtime configuration such as the Redis URL or environment
     specific options should be passed. The options can come from any dynamic
     source such as Mix Config, Vault, Etcd, environment variables, etc.

  The default `init/2` implementation uses `System.get_env/1` to read the
  `REDIS_URL` on boot. The default callback can be overridden to pull in
  additional configuration. For example, to grab values from
  `Application.get_env/2`:

      @impl Kiq
      def init(_reason, opts) do
        for_env = Application.get_env(:my_app, :kiq, [])

        opts =
          opts
          |> Keyword.merge(for_env)
          |> Keyword.put(:client_opts, [redis_url: System.get_env("REDIS_URL")])

        {:ok, opts}
      end

  The `opts` argument contains all configuration from stages 1 and 2 (the `use`
  macro and the call to `start_link/1`).

  ### Configuration Options

  * `client_opts` — A keyword list of options provided for the Kiq client. This
    is client specific, but for the default Redis adapter it must include
    `redis_url`.
  * `extra_reporters` — Additional reporters that your application will use to
    report errors, track external stats, etc. See [Error Handling][] for details.
  * `queues` — A keyword list of queues where each entry is the name of the
    queue and the concurrency setting. For example, setting `[default: 10,
    exports: 5, media: 5]` would start the queues `default`, `exports` and
    `media` with a combined concurrency of 20. The concurrency setting
    specifies how many jobs _each queue_ will run concurrently.
  * `schedulers` — A list of schedulers to run. The default schedulers are
    "retry" which is used to retry failed jobs with a backoff and "schedule",
    used to enqueue jobs at a specific time in the future. Set this to an empty
    list to disable all schedulers and allow Sidekiq to handle enqueuing
    retries and scheduled jobs.
  * `server?` — Whether to start the queue supervisors and start processing
    jobs or only start the client. This setting is useful for testing or
    deploying your application's web and workers separately.

  ## Unique Jobs

  Kiq supports Sidekiq Enterprise's [unique jobs][uniq]. This feature prevents
  enqueueing duplicate jobs while an original job is still pending. The
  operations that attempt to enforce uniqueness are _not_ atomic—uniquess is
  not guaranteed and should be considered best effort.

  Enable unique jobs for a worker by setting a unique time period:

      defmodule MyApp.Worker do
        use Kiq.Worker, unique_for: :timer.minutes(5)
      end

  ### Unlock Policy

  By default unique jobs will hold the unique lock until the job has ran
  successfully. This policy ensures that jobs will remain locked if there are
  any errors, but it is prone to race conditions in certain situations for
  longer running jobs.

  Generally it is best to stick with the default `:success` policy. However, if
  your job is effected by the race condition you can change your worker's
  policy:

      use Kiq.Worker, unique_for: :timer.minutes(60), unique_until: :start

  ### Caveats

  * Note that job uniqueness is calculated from the `class`, `args`, and
    `queue`. This means that jobs with identical args may be added to different
    queues.
  * Unique jobs enqueued by Sidekiq will be unlocked by Kiq, but they may not
    use the same lock value. This is due to differences between hashing Erlang
    terms and Ruby objects. To help ensure uniqueness always enqueue unique jobs
    from either Sidekiq or Kiq.

  [uniq]: https://github.com/mperham/sidekiq/wiki/Ent-Unique-Jobs
  """

  alias Kiq.{Client, Job, Timestamp}

  @type job_args :: map() | Keyword.t() | Job.t()
  @type job_opts :: [in: pos_integer(), at: DateTime.t()]

  @doc """
  Starts the client and possibly the supervision tree, returning `{:ok, pid}` when startup is
  successful.

  Returns `{:error, {:already_started, pid}}` if the tree is already started or `{:error, term}`
  in case anything else goes wrong.

  ## Options

  Any options passed to `start_link` will be merged with those provided in the `use` block.
  """
  @callback start_link(opts :: Keyword.t()) :: Supervisor.on_start()

  @doc """
  A callback executed when the supervision tree is started and possibly when configuration is
  read.

  The first argument is the context of the callback being invoked. In most circumstances this
  will be `:supervisor`. The second argument is a keyword list of the combined options passed
  to `use/1` and `start_link/1`.

  Application configuration is _not_ passed into the `init/2` callback. To use application
  config the callback must be overridden and merged manually.
  """
  @callback init(reason :: :supervisor, opts :: Keyword.t()) :: {:ok, Keyword.t()} | :ignore

  @doc """
  Clear all enqueued, scheduled and backup jobs.

  All known queues are cleared, even if they aren't listed in the current configuration.
  """
  @callback clear_all() :: :ok

  @doc """
  Enqueue a job to be processed asynchronously.

  Jobs can be enqueued from `Job` structs, maps or keyword lists.

  ## Options

  * `in` - The amount of time in seconds to wait before processing the job. This must be a
    positive integer.
  * `at` - A specific `DateTime` in the future when the job should be processed.

  ## Examples

      # Enqueue a job to be processed immediately
      MyJob.new([1, 2]) |> MyKiq.enqueue()

      # Enqueue a job in one minute
      MyJob.new([1, 2]) |> MyKiq.enqueue(in: 60)

      # Enqueue a job some time in the future
      MyJob.new([1, 2]) |> MyKiq.enqueue(at: ~D[2020-09-20 12:00:00])

      # Enqueue a job from scratch, without using a worker module
      MyKiq.enqueue(class: "ExternalWorker", args: [1])
  """
  @callback enqueue(job_args(), job_opts()) :: {:ok, Job.t()} | {:error, Exception.t()}

  @doc false
  defmacro __using__(opts) do
    quote do
      @behaviour Kiq

      @client_name Module.concat(__MODULE__, "Client")
      @reporter_name Module.concat(__MODULE__, "Reporter")
      @supervisor_name Module.concat(__MODULE__, "Supervisor")

      @opts unquote(opts)
            |> Keyword.put(:main, __MODULE__)
            |> Keyword.put(:name, @supervisor_name)
            |> Keyword.put(:client_name, @client_name)
            |> Keyword.put(:reporter_name, @reporter_name)

      @doc false
      def child_spec(opts) do
        %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, type: :supervisor}
      end

      @impl Kiq
      def start_link(opts \\ []) do
        @opts
        |> Keyword.merge(opts)
        |> Kiq.Supervisor.start_link()
      end

      @impl Kiq
      def init(reason, opts) when is_atom(reason) and is_list(opts) do
        client_opts = [redis_url: System.get_env("REDIS_URL")]

        {:ok, Keyword.put(opts, :client_opts, client_opts)}
      end

      @impl Kiq
      def clear_all do
        Kiq.Client.clear_all(@client_name)
      end

      @impl Kiq
      def enqueue(job_args, job_opts \\ []) when is_map(job_args) or is_list(job_args) do
        Kiq.enqueue(@client_name, job_args, job_opts)
      end

      defoverridable child_spec: 1, enqueue: 2, init: 2, start_link: 1
    end
  end

  @doc false
  def enqueue(client, job_args, job_opts) do
    job =
      job_args
      |> to_job()
      |> with_opts(job_opts)

    Client.enqueue(client, job)
  end

  defp to_job(%Job{} = job), do: job
  defp to_job(args), do: Job.new(args)

  defp with_opts(job, []), do: job
  defp with_opts(job, at: timestamp), do: %Job{job | at: timestamp}
  defp with_opts(job, in: seconds), do: %Job{job | at: Timestamp.unix_in(seconds)}
end
