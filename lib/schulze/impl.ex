defmodule Schulze.Impl do
  @moduledoc "Module for running Schulze method elections"
  alias Schulze.{Election, Repo}
  require Ecto.Query
  alias Ecto.Multi

  # import Ecto.Changeset

  def all_elections(nil, page) do
    Election
    |> Ecto.Query.order_by(asc: :id)
    |> Ecto.Query.where(is_common: true)
    |> paginate(page)
  end

  def all_elections(user_id, params) do
    Election
    |> Ecto.Query.order_by(asc: :id)
    |> Ecto.Query.where(user_id: ^user_id)
    |> paginate(params)
  end

  defp paginate(query, params) do
    %{entries: entries, page_number: page_number, total_pages: total_pages, page_size: page_size} =
      Repo.paginate(query, params)

    {entries, [page_number: page_number, total_pages: total_pages, page_size: page_size]}
  end

  # defp update(election) do
  #   changeset(election, %{ winners: term.winners})
  #   |> Repo.update()
  #   |> case do
  #     {:ok, %Election{} = term} -> {:ok, term}
  #     e -> e
  #   end
  # end

  @spec cast_vote(Election.t(), Election.vote()) ::
          {:ok, Election.t()} | {:error, any(), reason :: String.t(), any()}
  def cast_vote(election, vote) do
    # any candidates not in the vote will have their scores set to zero
    vote =
      (election.candidates -- Map.keys(vote))
      |> Enum.map(&{&1, 0})
      |> Enum.into(%{})
      |> Map.merge(vote)

    with :ok <- validate(election, vote),
         {:ok, election} <- update_with_vote(election, vote) do
      Schulze.broadcast("election_updates", "election_updated", %{id: election.id})
      {:ok, election}
    end
  end

  defp update_with_vote(election, vote) do
    Multi.new()
    |> Multi.run(:passwords, fn _, _ ->
      with query <-
             Ecto.Query.from(e in Election,
               select: e,
               where: [id: ^election.id],
               lock: "FOR UPDATE NOWAIT"
             ),
           [election] <- Repo.all(query),
           true <- not election.private or vote["password"] in election.passwords do
        {:ok, :ok}
      else
        [] -> {:error, "Can't find election"}
        false -> {:error, "Invalid password"}
      end
    end)
    |> Multi.run(:pull, fn _, %{passwords: _} ->
      Ecto.Query.from(e in Election, where: [id: ^election.id], where: is_nil(e.winners))
      |> Repo.update_all(pull: [passwords: vote["password"]])
      |> case do
        {1, x} -> {:ok, x}
        _ -> {:error, "Could not pull password"}
      end
    end)
    |> Multi.run(:push, fn _, _ ->
      Ecto.Query.from(e in Election,
        where: [id: ^election.id],
        where: is_nil(e.winners),
        select: e
      )
      |> Repo.update_all(push: [votes: Map.delete(vote, "password")])
      |> case do
        {1, [election]} -> {:ok, election}
        {0, _} -> {:error, "Cant vote in resulted elections"}
      end
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{push: election}} -> {:ok, election}
      x -> x
    end
  end

  def create_election(name, candidates, user_id, voters) do
    Election.new(%Election{}, %{
      name: name,
      candidates: candidates,
      user_id: user_id,
      voters: voters
    })
    |> Repo.insert()
  end

  def get_election(id) do
    Repo.get(Election, id)
  end

  def get_winner(%Election{id: id}) do
    Multi.new()
    |> Multi.run(:get, fn _, _ ->
      election =
        Ecto.Query.from(e in Election, where: e.id == ^id, lock: "FOR UPDATE NOWAIT")
        |> Repo.one()

      {:ok, election}
    end)
    |> Multi.run(:update, fn _, %{get: election} ->
      Election.winner(election, get_results(election))
      |> Repo.update()
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{update: election}} ->
        Schulze.broadcast("election_updates", "election_updated", %{id: election.id})
        {:ok, election}

      error ->
        error
    end
  end

  def delete_election(id) do
    case Repo.get(Election, id) do
      %Election{} = election -> Repo.delete(election)
      _ -> {:error, "Could not delete"}
    end
  end

  @spec new_election(String.t(), Election.candidate_list()) ::
          {:ok, Election.t()} | {:error, reason :: term()}
  def new_election(name, candidates) do
    cond do
      Enum.uniq(candidates) != candidates -> {:error, "Candidates must be unique"}
      length(candidates) < 2 -> {:error, "Need at least 2 candidates"}
      String.contains?(name, ":") -> {:error, "Invalid Character in Election name."}
      String.length(name) < 3 -> {:error, "Election Name not long enough"}
      true -> {:ok, %Election{name: name, candidates: candidates}}
    end
  end

  @spec get_pairs(list(a :: any())) :: list({any(), any()})
  defp get_pairs(list) do
    for c1 <- list, c2 <- list do
      if c1 != c2, do: {c1, c2}
    end
    |> Enum.reject(&is_nil(&1))
  end

  def get_results(election) do
    candidates = election.candidates
    votes = election.votes
    pairs = get_pairs(candidates)
    pairwise = Enum.map(pairs, fn {c1, c2} -> count_times_preferred(c1, c2, votes) end)
    g = build_graph(candidates, pairwise)

    results =
      Enum.map(pairs, fn {c1, c2} = pair ->
        {pair, get_strongest_path_weight(g, c1, c2)}
      end)
      |> get_pairwise_winners()
      |> Enum.frequencies()
      |> transpose_map()
      |> Enum.sort_by(fn {key, _} -> key end, &(&1 >= &2))
      |> Enum.map(fn {_, value} -> value end)

    missing_candidates = candidates -- List.flatten(results)

    results ++ [missing_candidates]
  end

  def transpose_map(map) do
    Enum.group_by(map, fn {_, value} -> value end, fn {key, _} -> key end)
  end

  defp sorted_pair({{c1, c2}, _}) do
    [a, b] = Enum.sort([c1, c2])
    {a, b}
  end

  # Counts the number of times `c1` is preferred to `c2` in `votes`
  defp count_times_preferred(c1, c2, votes) do
    c1_preferred_times =
      Enum.reduce(votes, 0, fn vote, acc ->
        c1_vote = Map.get(vote, c1, 0)
        c2_vote = Map.get(vote, c2, 0)
        if c1_vote > c2_vote, do: acc + 1, else: acc
      end)

    {{c1, c2}, c1_preferred_times}
  end

  defp get_pairwise_winners(pairwise) do
    pairwise
    |> Enum.group_by(&sorted_pair/1, fn {{c1, _}, preference} -> {c1, preference} end)
    |> Enum.map(fn {_pairing, [{c1, c1_votes}, {c2, c2_votes}]} ->
      cond do
        c1_votes > c2_votes -> c1
        c2_votes > c1_votes -> c2
        c1_votes == c2_votes -> nil
      end
    end)
    |> Enum.reject(&is_nil(&1))
  end

  defp build_graph(candidates, pairwise) do
    g =
      Graph.new()
      |> Graph.add_vertices([candidates])

    Enum.reduce(pairwise, g, fn {{c1, c2}, weight}, graph ->
      Graph.add_edge(graph, c1, c2, weight: weight)
    end)
  end

  defp get_strongest_path_weight(graph, node1, node2) do
    Graph.get_paths(graph, node1, node2)
    |> Enum.map(&get_path_strength(graph, &1))
    |> max_or_else(0)
  end

  defp get_path_strength(graph, path) do
    get_path_strength(graph, path, [])
  end

  defp get_path_strength(_graph, [_node | []], acc) do
    acc |> Enum.min()
  end

  defp get_path_strength(graph, [node | tail], acc) do
    [edge] = Graph.edges(graph, node, hd(tail))
    get_path_strength(graph, tail, [edge.weight | acc])
  end

  defp max_or_else([], x), do: x
  defp max_or_else(list, _), do: Enum.max(list)

  defp validate(election, vote) do
    vote
    |> Map.delete("password")
    |> Enum.reduce_while(:ok, fn {candidate, preference}, acc ->
      cond do
        preference < 0 -> {:halt, {:error, "Preferences cannot be negative"}}
        candidate not in election.candidates -> {:halt, {:error, "Candidate not on election"}}
        true -> {:cont, acc}
      end
    end)
  end
end
