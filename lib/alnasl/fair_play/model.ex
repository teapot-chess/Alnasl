defmodule Alnasl.FairPlay.Model do
  @moduledoc """
  What a player of a given rating is expected to do, as fitted on real
  games: the parameters behind `Alnasl.FairPlay.Stats`.

  Three parts, all fitted by `fit/2` from the per-ply records of
  `Alnasl.FairPlay.Analyzer`, and nothing else kept (no games, no names):

    * two logistic models, the chance of playing the engine's first choice
      (`match`) and of playing a move within 0.01 of it (`ev`), each from
      the same features (`features/1`): the rating, the scaled gap from the
      best move to the second, how many other moves are within 0.30 of the
      best, and the material left. The rating is not one straight line: a
      linear spline with a knot every 200 points from 1200 to 2600, so a
      1300 player is not assumed to be a 2500 player with the sign
      flipped, and the rating also bends the effect of the gap and of the
      number of good moves (a strong player finds the one good move more
      reliably than a weak one; that is rather the point of a rating).
      Then what else the label records already hold: how far from level
      the position is, the opponent's rating against the player's, and
      the share of their remaining time the player spent on the move
      (`prepare/1`). The number of legal moves would be another, but the
      label records do not keep it, and it is not worth a relabel;
      Ratings under 1000 are not scored at all
      (`Alnasl.FairPlay.Selection`, `:low_rating`). Fitted by Newton's
      method (IRLS) with a whisker of ridge, so a perfectly separable
      corner of the data gives a large coefficient rather than an
      infinite one;
    * the mean and variance of the scaled loss per rating band (200
      points) and position type (how many other moves are within 0.30:
      none, one, two or more), falling back to the band, then to all
      plies, where a cell has fewer than 30 plies;
    * how strongly the tests hang together within a ply, within a game
      and across the games of one player-event (`dispersion/1`, the
      `R0`, `W` and `B` of `Alnasl.FairPlay.Cluster`), from which each
      player-event's variance is built from its own games. Moves of one
      game are not independent, and a player's form on the day is not in
      the rating. The single global covariance of the z-scores that stood
      here before gave every player-event the inflation of the average
      one, and was measured on the very games the regression was fitted
      on. These are cross-fitted (`fit/2`): measured only on games the
      regression that judged them had not seen;
    * from the same cross-fitted residuals, the mean and spread of honest
      single-game scores by game length (`scan`), which the per-game scan
      of `Alnasl.FairPlay.Scan` is measured against. Optional in the file:
      a model without it has no scan, and the score is the event score
      alone;
    * from the same cross-fit, the correlation between the event score and
      the scan, by the number of games scanned (`union`, see
      `Alnasl.FairPlay.Union`). Optional too: without it the score is the
      plain larger of the two, as in format 2 files fitted before it;
    * the held-out false-positive table (`false_positives`): for each
      threshold, how many normal player-events scored that high, with a
      95% interval. Written by the fit (`Alnasl.FairPlay.Calibration`),
      read by the report. `nil` in a model fitted without one.

  A model belongs to one engine build and one node count: the json says
  which, and a model fitted on one is not used with another.

  ## The file

  `"format": 2`, with the feature names in the order the coefficients
  are in. A file whose features are not exactly this module's is refused
  (`{:error, {:unknown_features, names}}`) rather than read as if they
  were: coefficients applied to the wrong features give confident
  nonsense. A format-1 file (one straight rating line, independent moves
  and a global covariance) is refused too, `{:error, {:outdated_format,
  1}}`: its score is the one this format exists to replace, and the report
  says "not calibrated" until a new one is fitted rather than show it.
  No format-1 model ever shipped in a release.

  Saved as `priv/fair_play/model-<engine>.json`. The parameters are derived
  from Lichess broadcast games (database.lichess.org, CC BY-SA 4.0), and
  the file says so.
  """

  alias Alnasl.FairPlay.{Cluster, Scan, Selection, Stats, Union}

  @type t :: %__MODULE__{}

  # The likelihood-ratio weighting of the match tests (`weight/2`): the
  # share of moves the cheater it is tuned against takes from the engine.
  @theta 0.3

  defstruct engine: nil,
            bench: nil,
            nodes: nil,
            match: nil,
            ev: nil,
            loss: %{mean: nil, cells: %{}, bands: %{}, global: {0.0, 0.0, 0}},
            theta: @theta,
            dispersion: nil,
            scan: nil,
            union: nil,
            weights: [1.0, 1.0, 1.0],
            false_positives: nil,
            meta: %{}

  @min_cell 30
  @format 3
  # The knots of the rating spline: a hinge `max(rating − knot, 0)/400`
  # each, on top of the straight line.
  @knots [1200, 1400, 1600, 1800, 2000, 2200, 2400, 2600]
  @feature_names ~w(intercept rating) ++
                   Enum.map(@knots, &"rating>#{&1}") ++
                   ~w(scaled_gap near_count material rating*scaled_gap rating*near_count) ++
                   ~w(abs_eval opponent think think_known) ++
                   ~w(eval move move>40 spread few_lines clock clock_known)
  # The floors under what the loss regression may predict: a mean of
  # nothing and a variance of nothing are both lies.
  @min_loss_mean 0.005
  @min_loss_var 1.0e-4
  @attribution "Parameters derived from Lichess broadcast games (database.lichess.org), " <>
                 "licensed CC BY-SA 4.0; this file is under the same licence."

  # --- prediction --------------------------------------------------------------

  @doc """
  The features of a ply, in the order of `feature_names/0`: `1`, the
  rating as `(rating − 2000)/400`, a hinge `max(rating − k, 0)/400` per
  knot `k` (1200, 1400, ... 2600), the scaled gap, the near count (at most
  3), material/78, the rating times the gap and times the near count, and
  then:

    * `abs_eval` - the best line's evaluation, either sign, in pawns (at
      most 3: beyond that the ply is `:decided` and not counted);
    * `opponent` - `(opponent's rating − rating)/400`, between −2 and 2;
      0 when the opponent's rating is not known, as if they were equal;
    * `think`, `think_known` - the share of the clock the move took
      (`prepare/1`), and 1 when that is known; 0 and 0 when it is not.

  Scaled so the coefficients come out of comparable size, which Newton's
  method appreciates.
  """
  @spec features(map()) :: [float()]
  def features(record) do
    r = (record.rating - 2000) / 400
    gap = Stats.scaled_gap(record)
    near = min(record.near_count || 0, 3) / 1
    think = record[:think]
    move = (move_number(record) - 30) / 20
    clock = record[:clock_before_ms]

    [1.0, r] ++
      Enum.map(@knots, &(max(record.rating - &1, 0) / 400)) ++
      [gap, near, record.material / 78, r * gap, r * near] ++
      [abs_eval(record), opponent(record), think || 0.0, if(think, do: 1.0, else: 0.0)] ++
      [
        eval(record),
        move |> max(-1.5) |> min(2.5),
        max(move - 0.5, 0.0),
        spread(record),
        if(length(record[:best] || []) < 4, do: 1.0, else: 0.0),
        if(is_integer(clock), do: min(clock, 3_600_000) / 3_600_000, else: 0.0),
        if(is_integer(clock), do: 1.0, else: 0.0)
      ]
  end

  # The move number: the record's, or from the ply (the label files keep
  # only that), or the middle of a game when neither is known.
  defp move_number(%{move_number: n}) when is_integer(n), do: n
  defp move_number(%{ply: ply}) when is_integer(ply), do: div(ply + 1, 2)
  defp move_number(_record), do: 30

  defp abs_eval(%{best: [%{cp: cp} | _]}), do: min(abs(cp), 300) / 100
  defp abs_eval(_record), do: 0.0

  # The evaluation with its sign, from the mover's side, in pawns.
  defp eval(%{best: [%{cp: cp} | _]}), do: (cp / 100) |> max(-3.0) |> min(3.0)
  defp eval(_record), do: 0.0

  # The scaled gap from the best line to the last the engine gave: how
  # far the four choices are spread. One line: as wide as it gets.
  defp spread(%{best: [%{cp: best} | _] = lines}) when length(lines) > 1 do
    %{cp: last} = List.last(lines)
    min(max(best - last, 0) / 100 / (1 + abs(best) / 100), 5.0)
  end

  defp spread(_record), do: 5.0

  @doc """
  The weight of a match test's ply under the likelihood-ratio weighting:
  `log(1 + θ/((1 − θ)·p))`, the log of the odds a cheater who takes a
  share `θ` of their moves from the engine, and otherwise plays like the
  player, would have produced a match here against the player alone. A
  match where the model gave the move a 20% chance says more than one
  where it gave 80%, and this says how much more; the plain count weighs
  them alike. `θ` nil or 0: every ply weighs one, the plain test.
  """
  @spec weight(t() | number() | nil, float()) :: float()
  def weight(%__MODULE__{theta: theta}, p), do: weight(theta, p)
  def weight(theta, _p) when theta in [nil, 0, 0.0], do: 1.0

  def weight(theta, p) when is_number(theta) and theta > 0 and theta < 1,
    do: :math.log(1 + theta / ((1 - theta) * max(p, 1.0e-6)))

  @doc "The likelihood-ratio weighting the fit uses unless told otherwise."
  def default_theta, do: @theta

  defp opponent(%{opponent_rating: opp, rating: own}) when is_integer(opp) and opp > 0,
    do: ((opp - own) / 400) |> max(-2.0) |> min(2.0)

  defp opponent(_record), do: 0.0

  @doc """
  Adds `:think` to every record of one player: the share of the time on
  their clock before the move that the move took, from the clock before
  their next move in the same game, between 0 and 1 - or `nil` when
  either clock is unknown, when it is the last move they made in that
  game, or when an increment paid back more than the move took (which
  reads as no time at all, and is clamped to 0, not left out).

  Plies of one game are told apart by `:game` and must be numbered by
  `:ply`, as both the boards and the label files have them. Skipped
  plies count as the next move when they have a clock: the board does
  not care why a move was left out.
  """
  @spec prepare([map()]) :: [map()]
  def prepare(records) do
    clocks =
      for r <- records, is_integer(r[:clock_before_ms]), into: %{} do
        {{r[:game], r[:ply]}, r[:clock_before_ms]}
      end

    Enum.map(records, fn r -> Map.put(r, :think, think(r, clocks)) end)
  end

  defp think(%{clock_before_ms: before, ply: ply} = r, clocks)
       when is_integer(before) and before > 0 and is_integer(ply) do
    case clocks[{r[:game], ply + 2}] do
      next when is_integer(next) -> ((before - next) / before) |> max(0.0) |> min(1.0)
      nil -> nil
    end
  end

  defp think(_record, _clocks), do: nil

  def feature_names, do: @feature_names

  @doc """
  The correlations `Alnasl.FairPlay.Cluster` builds a player-event's
  variance from; independent plies (`Cluster.default/0`) for a model
  without them.
  """
  def dispersion(%__MODULE__{dispersion: %{} = params}), do: params
  def dispersion(%__MODULE__{}), do: Cluster.default()

  @doc "The model's chance that this ply is the engine's first choice."
  def p_match(%__MODULE__{match: beta}, record), do: logistic(dot(beta, features(record)))

  @doc "The model's chance that this ply is within 0.01 of the best."
  def p_ev(%__MODULE__{ev: beta}, record), do: logistic(dot(beta, features(record)))

  @doc """
  `{mean, variance}` of the scaled loss expected at this ply: the mean
  from the loss regression over `features/1` (floored at a small positive
  number: a loss cannot be expected to be negative), the variance from
  the table of squared residuals per rating band and position type,
  falling back to the band, then to all plies.
  """
  def loss_moments(%__MODULE__{loss: loss}, record) do
    band = band(record.rating)

    {cell_mean, var, _n} =
      case loss.cells[cell(band, kind(record))] do
        {_, _, n} = found when n >= @min_cell ->
          found

        _ ->
          case loss.bands[band] do
            {_, _, n} = found when n >= @min_cell -> found
            _ -> loss.global
          end
      end

    mean =
      case loss[:mean] do
        beta when is_list(beta) -> max(dot(beta, features(record)), @min_loss_mean)
        _none -> cell_mean
      end

    {mean, max(var, @min_loss_var)}
  end

  @doc "The 200-point band a rating is in, from 1000 to 2800."
  def band(rating), do: rating |> div(200) |> Kernel.*(200) |> max(1000) |> min(2800)

  @doc "The position type: how many other moves were within 0.30 of the best (2 means two or more)."
  def kind(record), do: min(record.near_count || 0, 2)

  defp cell(band, kind), do: "#{band}:#{kind}"

  defp logistic(x) when x >= 0, do: 1 / (1 + :math.exp(-x))
  defp logistic(x), do: :math.exp(x) / (1 + :math.exp(x))

  defp dot(a, b), do: a |> Enum.zip(b) |> Enum.reduce(0.0, fn {x, y}, acc -> acc + x * y end)

  # --- fitting -----------------------------------------------------------------

  @doc """
  Fits a model from player-events: each a list of one player's records in
  one event, or `{key, records}` with a key that says which event (the
  calibration passes the event's name). Skipped plies are ignored.
  Options: `:engine`, `:bench`, `:nodes` (stored as they are), `:meta` (a
  map, merged into the json's meta), `:lambda` (ridge, default 1.0e-4),
  `:theta` (the likelihood-ratio weighting, `weight/2`; `default_theta/0`),
  `:weights` (of the three tests in the combined score; one each unless
  told otherwise - the benchmark of `Alnasl.FairPlay.Power` is where a
  different vector earns its place).

  ## Cross-fitted

  The regressions and the loss table are fitted on all the player-events.
  The correlations of `Alnasl.FairPlay.Cluster` are not, because a model's
  residuals on its own data are smaller than on anybody else's, and a
  variance measured on them is the variance of a model that has seen the
  answers. So the events are split in two by a hash of their key (the
  same split every run, and a whole event on one side); a model is fitted
  on each half, and the residual sums of the *other* half are what the
  correlations are measured on, both halves pooled. The correlations are
  then those of a model fitted on half the data, judged on data it did
  not see: if anything slightly too wide for the model fitted on all of
  it, which is the side to err on. With fewer than two events per half
  there is nothing to measure and the model has none (`dispersion/1`
  falls back to independent plies).

  The honest single-game scores the scan is judged against
  (`Alnasl.FairPlay.Scan`) come from the same cross-fitted residuals, with
  the correlations just measured: the scan's null is one the model never
  saw the answers to either. No cross-fit, no scan.

  The same cross-fit then pairs each player-event's event score with its
  scan and measures how far the two move together, by the number of games
  scanned (`Alnasl.FairPlay.Union`): what turns "the larger of two" back
  into a z.
  """
  @spec fit([[map()] | {term(), [map()]}], keyword()) :: t()
  def fit(events, opts \\ []) do
    keyed =
      events
      |> Enum.with_index()
      |> Enum.map(fn
        {{key, records}, _i} -> {key, records}
        {records, i} -> {i, records}
      end)

    all = Enum.map(keyed, &elem(&1, 1))
    regression = Task.async(fn -> regression(all, opts) end)
    halves = Enum.split_with(keyed, &(fold(elem(&1, 0)) == 0))
    {dispersion, scan, union} = cross_fitted(halves, opts)
    model = Task.await(regression, :infinity)

    %{
      model
      | engine: opts[:engine],
        bench: opts[:bench],
        nodes: opts[:nodes],
        dispersion: dispersion,
        scan: scan,
        union: union,
        weights: Keyword.get(opts, :weights, model.weights),
        meta:
          Map.merge(
            %{
              "plies" => model.meta["plies"],
              "player_events" => length(events),
              "dispersion" => "cross-fitted, two halves by event",
              "attribution" => @attribution
            },
            opts[:meta] || %{}
          )
    }
  end

  @doc "Which half (0 or 1) an event's key falls in, for the cross-fit: by hash, so every run agrees."
  def fold(key) do
    text = if is_binary(key), do: key, else: inspect(key)
    <<byte, _::binary>> = :crypto.hash(:sha256, "fold:" <> text)
    rem(byte, 2)
  end

  # The regressions and the loss table, nothing else. Public for
  # `Alnasl.FairPlay.Probes`, which cross-fits its own tests the same way.
  @doc false
  def regression(events, opts) do
    counted = events |> Enum.flat_map(&prepare/1) |> Enum.filter(&Selection.counted?/1)
    rows = Enum.map(counted, &features/1)
    lambda = Keyword.get(opts, :lambda, 1.0e-4)

    match =
      Task.async(fn ->
        logistic_fit(
          rows,
          Enum.map(counted, &if(Stats.engine_match?(&1), do: 1, else: 0)),
          lambda
        )
      end)

    ev = logistic_fit(rows, Enum.map(counted, &if(Stats.ev_match?(&1), do: 1, else: 0)), lambda)

    %__MODULE__{
      match: Task.await(match, :infinity),
      ev: ev,
      loss: loss_table(counted, rows, lambda),
      theta: Keyword.get(opts, :theta, @theta),
      meta: %{"plies" => length(counted)}
    }
  end

  @doc """
  Ridge least squares: the coefficients of `rows` on `ys`, `(XᵀX + λI)⁻¹ Xᵀy`.
  """
  @spec least_squares([[float()]], [float()], float()) :: [float()]
  def least_squares([], _ys, _lambda), do: List.duplicate(0.0, length(@feature_names))

  def least_squares([first | _] = rows, ys, lambda) do
    k = length(first)
    zero = for _ <- 1..k, do: List.duplicate(0.0, k)

    {xtx, xty} =
      rows
      |> Enum.zip(ys)
      |> Enum.reduce({zero, List.duplicate(0.0, k)}, fn {x, y}, {a, b} ->
        a =
          Enum.zip_with(a, x, fn row, xi ->
            Enum.zip_with(row, x, fn aij, xj -> aij + xi * xj end)
          end)

        b = Enum.zip_with(b, x, fn bi, xi -> bi + y * xi end)
        {a, b}
      end)

    xtx =
      xtx
      |> Enum.with_index()
      |> Enum.map(fn {row, i} -> List.update_at(row, i, &(&1 + lambda)) end)

    solve(xtx, xty)
  end

  defp cross_fitted({a, b}, opts) when length(a) >= 2 and length(b) >= 2 do
    a = Enum.map(a, &elem(&1, 1))
    b = Enum.map(b, &elem(&1, 1))
    on_a = Task.async(fn -> regression(a, opts) end)
    on_b = regression(b, opts)
    on_a = Task.await(on_a, :infinity)

    plies = Enum.map(b, &Stats.residuals(&1, on_a)) ++ Enum.map(a, &Stats.residuals(&1, on_b))
    dispersion = plies |> Enum.map(&Cluster.accumulate/1) |> Cluster.fit()
    scan = plies |> Enum.flat_map(&Scan.game_scores(&1, dispersion)) |> Scan.fit()
    union = plies |> Enum.flat_map(&union_pair(&1, dispersion, scan)) |> Union.fit()
    {dispersion, scan, union}
  end

  defp cross_fitted(_halves, _opts), do: {nil, nil, nil}

  # The event score and the scan of one player-event with a score, for the
  # correlation `Alnasl.FairPlay.Union` corrects the larger of them with.
  defp union_pair(plies, dispersion, scan) do
    with true <- length(plies) >= Stats.min_moves(),
         {zs, corr} = plies |> Cluster.accumulate() |> Cluster.z_scores(dispersion),
         event when is_number(event) <- Stats.combined(zs, [1.0, 1.0, 1.0], corr),
         {z, _game, games} <- Scan.result(plies, dispersion, scan) do
      [{event, z, games}]
    else
      _ -> []
    end
  end

  @doc """
  Logistic regression by Newton's method: `rows` are feature lists, `ys`
  zeros and ones. Returns the coefficients. Stops when no coefficient
  moves by more than 1e-9, or after 50 steps.
  """
  @spec logistic_fit([[float()]], [0 | 1], float()) :: [float()]
  def logistic_fit([], _ys, _lambda), do: List.duplicate(0.0, length(@feature_names))

  def logistic_fit([first | _] = rows, ys, lambda) do
    k = length(first)
    newton(rows, ys, lambda, List.duplicate(0.0, k), 50)
  end

  defp newton(_rows, _ys, _lambda, beta, 0), do: beta

  defp newton(rows, ys, lambda, beta, steps) do
    k = length(beta)
    zero_h = for _ <- 1..k, do: List.duplicate(0.0, k)

    {gradient, hessian} =
      rows
      |> Enum.zip(ys)
      |> Enum.reduce({List.duplicate(0.0, k), zero_h}, fn {x, y}, {g, h} ->
        p = logistic(dot(beta, x))
        w = p * (1 - p)
        g = Enum.zip_with(g, x, fn gi, xi -> gi + (y - p) * xi end)

        h =
          Enum.zip_with(h, x, fn row, xi ->
            Enum.zip_with(row, x, fn hij, xj -> hij + w * xi * xj end)
          end)

        {g, h}
      end)

    # The ridge: it keeps the matrix invertible and the coefficients finite.
    gradient = Enum.zip_with(gradient, beta, fn g, b -> g - lambda * b end)

    hessian =
      hessian
      |> Enum.with_index()
      |> Enum.map(fn {row, i} -> List.update_at(row, i, &(&1 + lambda)) end)

    step = solve(hessian, gradient)
    beta = Enum.zip_with(beta, step, &(&1 + &2))

    if Enum.all?(step, &(abs(&1) < 1.0e-9)),
      do: beta,
      else: newton(rows, ys, lambda, beta, steps - 1)
  end

  @doc "Solves `a x = b` by Gaussian elimination with partial pivoting. Small systems only."
  @spec solve([[float()]], [float()]) :: [float()]
  def solve(a, b) do
    n = length(b)
    m = Enum.zip_with(a, b, fn row, bi -> List.to_tuple(row ++ [bi]) end) |> List.to_tuple()

    m =
      Enum.reduce(0..(n - 1), m, fn col, m ->
        pivot = Enum.max_by(col..(n - 1), &abs(elem(elem(m, &1), col)))
        m = swap(m, col, pivot)
        p = elem(elem(m, col), col)

        if p == 0 do
          m
        else
          Enum.reduce((col + 1)..(n - 1)//1, m, fn r, m ->
            factor = elem(elem(m, r), col) / p
            row = elem(m, r)
            prow = elem(m, col)
            new = for j <- 0..n, into: [], do: elem(row, j) - factor * elem(prow, j)
            put_elem(m, r, List.to_tuple(new))
          end)
        end
      end)

    Enum.reduce((n - 1)..0//-1, %{}, fn i, x ->
      row = elem(m, i)
      sum = Enum.reduce((i + 1)..(n - 1)//1, 0.0, fn j, s -> s + elem(row, j) * x[j] end)
      p = elem(row, i)
      Map.put(x, i, if(p == 0, do: 0.0, else: (elem(row, n) - sum) / p))
    end)
    |> then(fn x -> for i <- 0..(n - 1), do: x[i] end)
  end

  defp swap(m, i, i), do: m
  defp swap(m, i, j), do: m |> put_elem(i, elem(m, j)) |> put_elem(j, elem(m, i))

  # The expected loss: a regression on the features for the mean, and
  # the squared residuals about it per band and position type for the
  # variance, where a cell of 30 plies has something to say. The mean is
  # what moves the ASD test; the old table knew the band and the number of
  # good moves and nothing about the gap, the evaluation or the clock, and
  # the lowest bands paid for it.
  defp loss_table(counted, rows, lambda) do
    losses = Enum.map(counted, &Stats.scaled_loss/1)
    mean = least_squares(rows, losses, lambda)

    with_residual =
      counted
      |> Enum.zip(rows)
      |> Enum.zip_with(losses, fn {r, x}, loss ->
        predicted = max(dot(mean, x), @min_loss_mean)
        {r, loss - predicted}
      end)

    %{
      mean: mean,
      cells:
        with_residual
        |> Enum.group_by(fn {r, _} -> cell(band(r.rating), kind(r)) end, &elem(&1, 1))
        |> Map.new(fn {key, residuals} -> {key, moments(residuals)} end),
      bands:
        with_residual
        |> Enum.group_by(fn {r, _} -> band(r.rating) end, &elem(&1, 1))
        |> Map.new(fn {key, residuals} -> {key, moments(residuals)} end),
      global: with_residual |> Enum.map(&elem(&1, 1)) |> moments()
    }
  end

  # `{mean, variance about zero, n}` of residuals: the variance is of the
  # residual itself, not about its own mean, so a cell the regression
  # misses by a little pays for it in spread rather than hiding it.
  defp moments([]), do: {0.0, 0.0, 0}

  defp moments(xs) do
    n = length(xs)
    mean = Enum.sum(xs) / n
    var = Enum.reduce(xs, 0.0, &(&1 * &1 + &2)) / max(n - 1, 1)
    {mean, var, n}
  end

  # --- files -------------------------------------------------------------------

  @doc "Where the model of an engine lives: `priv/fair_play/model-<engine>.json`."
  def path(engine_id, dir \\ nil),
    do:
      Path.join(dir || Application.app_dir(:alnasl, "priv/fair_play"), "model-#{engine_id}.json")

  @doc "The model of an engine, or `{:error, :missing}` until one is calibrated."
  @spec load(String.t(), String.t() | nil) :: {:ok, t()} | {:error, :missing | term()}
  def load(engine_id, dir \\ nil) do
    case read(path(engine_id, dir)) do
      {:error, :enoent} -> {:error, :missing}
      other -> other
    end
  end

  @doc "The model in the json file at `path`, wherever it is."
  @spec read(String.t()) :: {:ok, t()} | {:error, term()}
  def read(path) do
    with {:ok, text} <- File.read(path),
         {:ok, json} <- Jason.decode(text),
         do: from_json(json)
  end

  @doc "Writes a model to `path` as json."
  def save(%__MODULE__{} = model, path) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode_to_iodata!(to_json(model), pretty: true))
  end

  def to_json(%__MODULE__{} = m) do
    triple = fn {mean, var, n} -> [mean, var, n] end

    %{
      "format" => @format,
      "engine" => m.engine,
      "bench" => m.bench,
      "nodes" => m.nodes,
      "features" => @feature_names,
      "match" => m.match,
      "ev" => m.ev,
      "theta" => m.theta,
      "loss" => %{
        "mean" => m.loss[:mean],
        "cells" => Map.new(m.loss.cells, fn {k, v} -> {k, triple.(v)} end),
        "bands" => Map.new(m.loss.bands, fn {k, v} -> {Integer.to_string(k), triple.(v)} end),
        "global" => triple.(m.loss.global)
      },
      "dispersion" => m.dispersion && Cluster.to_json(m.dispersion),
      "scan" => Scan.to_json(m.scan),
      "union" => Union.to_json(m.union),
      "weights" => m.weights,
      "false_positives" => m.false_positives,
      "meta" => m.meta
    }
  end

  def from_json(%{"format" => @format, "features" => @feature_names} = j) do
    triple = fn [mean, var, n] -> {mean / 1, var / 1, n} end

    {:ok,
     %__MODULE__{
       engine: j["engine"],
       bench: j["bench"],
       nodes: j["nodes"],
       match: Enum.map(j["match"], &(&1 / 1)),
       ev: Enum.map(j["ev"], &(&1 / 1)),
       theta: j["theta"],
       loss: %{
         mean: j["loss"]["mean"] && Enum.map(j["loss"]["mean"], &(&1 / 1)),
         cells: Map.new(j["loss"]["cells"], fn {k, v} -> {k, triple.(v)} end),
         bands: Map.new(j["loss"]["bands"], fn {k, v} -> {String.to_integer(k), triple.(v)} end),
         global: triple.(j["loss"]["global"])
       },
       dispersion: Cluster.from_json(j["dispersion"]),
       scan: Scan.from_json(j["scan"]),
       union: Union.from_json(j["union"]),
       weights: j["weights"],
       false_positives: j["false_positives"],
       meta: j["meta"] || %{}
     }}
  end

  def from_json(%{"format" => @format, "features" => names}),
    do: {:error, {:unknown_features, names}}

  def from_json(%{"format" => old}) when is_integer(old) and old < @format,
    do: {:error, {:outdated_format, old}}

  def from_json(_other), do: {:error, :unknown_format}

  @doc "The format `to_json/1` writes."
  def format, do: @format
end
