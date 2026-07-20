defmodule SymphonyElixir.Linear.Client do
  @moduledoc """
  Thin Linear GraphQL client for polling candidate issues.
  """

  require Logger
  alias SymphonyElixir.Config
  alias SymphonyElixir.Tracker.Issue

  @issue_page_size 50
  @comment_page_size 50
  @max_error_body_log_bytes 1_000

  @project_query """
  query SymphonyLinearProjectPoll($projectSlug: String!, $stateNames: [String!]!, $first: Int!, $relationFirst: Int!, $after: String) {
    issues(filter: {project: {slugId: {eq: $projectSlug}}, state: {name: {in: $stateNames}}}, first: $first, after: $after) {
      nodes {
        id
        identifier
        title
        description
        priority
        state {
          name
        }
        branchName
        url
        assignee {
          id
        }
        labels {
          nodes {
            name
          }
        }
        inverseRelations(first: $relationFirst) {
          nodes {
            type
            issue {
              id
              identifier
              state {
                name
              }
            }
          }
        }
        createdAt
        updatedAt
      }
      pageInfo {
        hasNextPage
        endCursor
      }
    }
  }
  """

  @team_query """
  query SymphonyLinearTeamPoll($teamKey: String!, $stateNames: [String!]!, $first: Int!, $relationFirst: Int!, $after: String) {
    issues(filter: {team: {key: {eq: $teamKey}}, state: {name: {in: $stateNames}}}, first: $first, after: $after) {
      nodes {
        id
        identifier
        title
        description
        priority
        state {
          name
        }
        branchName
        url
        assignee {
          id
        }
        labels {
          nodes {
            name
          }
        }
        inverseRelations(first: $relationFirst) {
          nodes {
            type
            issue {
              id
              identifier
              state {
                name
              }
            }
          }
        }
        createdAt
        updatedAt
      }
      pageInfo {
        hasNextPage
        endCursor
      }
    }
  }
  """

  @project_query_by_ids """
  query SymphonyLinearProjectIssuesById($ids: [ID!]!, $projectSlug: String!, $first: Int!, $relationFirst: Int!) {
    issues(filter: {id: {in: $ids}, project: {slugId: {eq: $projectSlug}}}, first: $first) {
      nodes {
        id
        identifier
        title
        description
        priority
        state {
          name
        }
        branchName
        url
        assignee {
          id
        }
        labels {
          nodes {
            name
          }
        }
        inverseRelations(first: $relationFirst) {
          nodes {
            type
            issue {
              id
              identifier
              state {
                name
              }
            }
          }
        }
        createdAt
        updatedAt
      }
    }
  }
  """

  @team_query_by_ids """
  query SymphonyLinearTeamIssuesById($ids: [ID!]!, $teamKey: String!, $first: Int!, $relationFirst: Int!) {
    issues(filter: {id: {in: $ids}, team: {key: {eq: $teamKey}}}, first: $first) {
      nodes {
        id
        identifier
        title
        description
        priority
        state {
          name
        }
        branchName
        url
        assignee {
          id
        }
        labels {
          nodes {
            name
          }
        }
        inverseRelations(first: $relationFirst) {
          nodes {
            type
            issue {
              id
              identifier
              state {
                name
              }
            }
          }
        }
        createdAt
        updatedAt
      }
    }
  }
  """

  @comments_query """
  query SymphonyLinearIssueComments($issueId: String!, $first: Int!, $after: String) {
    issue(id: $issueId) {
      comments(first: $first, after: $after) {
        nodes {
          body
          user {
            id
          }
        }
        pageInfo {
          hasNextPage
          endCursor
        }
      }
    }
  }
  """

  @viewer_query """
  query SymphonyLinearViewer {
    viewer {
      id
    }
  }
  """

  @spec fetch_issues_by_states([String.t()], keyword()) ::
          {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names, opts \\ []) when is_list(state_names) and is_list(opts) do
    normalized_states = Enum.map(state_names, &to_string/1) |> Enum.uniq()

    case normalized_states do
      [] ->
        {:ok, []}

      states ->
        with {:ok, tracker} <- configured_tracker_for_read(),
             {:ok, scope} <- tracker_scope(tracker),
             {:ok, assignee_filter} <- routing_assignee_filter() do
          do_fetch_by_states(
            scope,
            states,
            assignee_filter,
            required_comment_for_fetch(tracker.required_comment, opts),
            tracker.required_labels
          )
        end
    end
  end

  @spec fetch_issues_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_ids(issue_ids) when is_list(issue_ids) do
    ids = Enum.uniq(issue_ids)

    case ids do
      [] ->
        {:ok, []}

      ids ->
        with {:ok, tracker} <- configured_tracker_for_read(),
             {:ok, scope} <- tracker_scope(tracker),
             {:ok, assignee_filter} <- routing_assignee_filter() do
          do_fetch_issue_states(
            ids,
            scope,
            assignee_filter,
            tracker.required_comment,
            tracker.required_labels
          )
        end
    end
  end

  @spec graphql(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def graphql(query, variables \\ %{}, opts \\ [])
      when is_binary(query) and is_map(variables) and is_list(opts) do
    payload = build_graphql_payload(query, variables, Keyword.get(opts, :operation_name))
    tracker_settings = Keyword.get_lazy(opts, :tracker_settings, fn -> Config.settings!().tracker end)

    request_fun =
      Keyword.get(opts, :request_fun, fn request_payload, headers ->
        post_graphql_request(request_payload, headers, tracker_settings.endpoint)
      end)

    with {:ok, headers} <- graphql_headers(tracker_settings),
         {:ok, %{status: 200, body: body}} <- request_fun.(payload, headers) do
      {:ok, body}
    else
      {:ok, response} ->
        Logger.error(
          "Linear GraphQL request failed status=#{response.status}" <>
            linear_error_context(payload, response)
        )

        {:error, {:linear_api_status, response.status}}

      {:error, reason} ->
        Logger.error("Linear GraphQL request failed: #{inspect(reason)}")
        {:error, {:linear_api_request, reason}}
    end
  end

  @doc false
  @spec normalize_issue_for_test(map()) :: Issue.t() | nil
  def normalize_issue_for_test(issue) when is_map(issue) do
    normalize_issue(issue, nil)
  end

  @doc false
  @spec normalize_issue_for_test(map(), String.t() | nil) :: Issue.t() | nil
  def normalize_issue_for_test(issue, assignee) when is_map(issue) do
    assignee_filter =
      case assignee do
        value when is_binary(value) ->
          case build_assignee_filter(value) do
            {:ok, filter} -> filter
            {:error, _reason} -> nil
          end

        _ ->
          nil
      end

    normalize_issue(issue, assignee_filter)
  end

  @doc false
  @spec next_page_cursor_for_test(map()) :: {:ok, String.t()} | :done | {:error, term()}
  def next_page_cursor_for_test(page_info) when is_map(page_info), do: next_page_cursor(page_info)

  @doc false
  @spec merge_issue_pages_for_test([[Issue.t()]]) :: [Issue.t()]
  def merge_issue_pages_for_test(issue_pages) when is_list(issue_pages) do
    issue_pages
    |> Enum.reduce([], &prepend_page_issues/2)
    |> finalize_paginated_issues()
  end

  @doc false
  @spec fetch_issues_by_ids_for_test([String.t()], (String.t(), map() -> {:ok, map()} | {:error, term()})) ::
          {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_ids_for_test(issue_ids, graphql_fun)
      when is_list(issue_ids) and is_function(graphql_fun, 2) do
    fetch_issues_by_ids_for_test(issue_ids, graphql_fun, [])
  end

  @doc false
  @spec fetch_issues_by_ids_for_test(
          [String.t()],
          (String.t(), map() -> {:ok, map()} | {:error, term()}),
          keyword()
        ) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_ids_for_test(issue_ids, graphql_fun, opts)
      when is_list(issue_ids) and is_function(graphql_fun, 2) and is_list(opts) do
    ids = Enum.uniq(issue_ids)

    case ids do
      [] ->
        {:ok, []}

      ids ->
        with {:ok, assignee_filter} <- build_test_assignee_filter(opts) do
          do_fetch_issue_states(
            ids,
            Keyword.get(opts, :scope, {:project, "test-project"}),
            assignee_filter,
            Keyword.get(opts, :required_comment),
            Keyword.get(opts, :required_labels, []),
            graphql_fun
          )
        end
    end
  end

  @doc false
  @spec fetch_issues_by_states_for_test(
          [String.t()],
          (String.t(), map() -> {:ok, map()} | {:error, term()}),
          keyword()
        ) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states_for_test(state_names, graphql_fun, opts \\ [])
      when is_list(state_names) and is_function(graphql_fun, 2) and is_list(opts) do
    with {:ok, assignee_filter} <- build_test_assignee_filter(opts) do
      do_fetch_by_states(
        Keyword.get(opts, :scope, {:project, "test-project"}),
        state_names,
        assignee_filter,
        required_comment_for_fetch(Keyword.get(opts, :required_comment), opts),
        Keyword.get(opts, :required_labels, []),
        graphql_fun
      )
    end
  end

  defp do_fetch_by_states(scope, state_names, assignee_filter, required_comment, required_labels) do
    do_fetch_by_states(scope, state_names, assignee_filter, required_comment, required_labels, &graphql/2)
  end

  defp do_fetch_by_states(
         scope,
         state_names,
         assignee_filter,
         required_comment,
         required_labels,
         graphql_fun
       ) do
    do_fetch_by_states_page(
      scope,
      state_names,
      assignee_filter,
      required_comment,
      required_labels,
      graphql_fun,
      nil,
      []
    )
  end

  defp do_fetch_by_states_page(
         scope,
         state_names,
         assignee_filter,
         required_comment,
         required_labels,
         graphql_fun,
         after_cursor,
         acc_issues
       ) do
    {query, variables} =
      scope_query(
        scope,
        @project_query,
        @team_query,
        %{
          stateNames: state_names,
          first: @issue_page_size,
          relationFirst: @issue_page_size,
          after: after_cursor
        }
      )

    with {:ok, body} <-
           graphql_fun.(query, variables),
         {:ok, issues, page_info} <- decode_linear_page_response(body, assignee_filter),
         {:ok, issues} <-
           apply_required_comment_gate(
             issues,
             required_comment,
             required_labels,
             assignee_filter,
             graphql_fun
           ) do
      updated_acc = prepend_page_issues(issues, acc_issues)

      case next_page_cursor(page_info) do
        {:ok, next_cursor} ->
          do_fetch_by_states_page(
            scope,
            state_names,
            assignee_filter,
            required_comment,
            required_labels,
            graphql_fun,
            next_cursor,
            updated_acc
          )

        :done ->
          {:ok, finalize_paginated_issues(updated_acc)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp prepend_page_issues(issues, acc_issues) when is_list(issues) and is_list(acc_issues) do
    Enum.reverse(issues, acc_issues)
  end

  defp finalize_paginated_issues(acc_issues) when is_list(acc_issues), do: Enum.reverse(acc_issues)

  defp do_fetch_issue_states(ids, scope, assignee_filter, required_comment, required_labels) do
    do_fetch_issue_states(
      ids,
      scope,
      assignee_filter,
      required_comment,
      required_labels,
      &graphql/2
    )
  end

  defp do_fetch_issue_states(
         ids,
         scope,
         assignee_filter,
         required_comment,
         required_labels,
         graphql_fun
       )
       when is_list(ids) and is_function(graphql_fun, 2) do
    issue_order_index = issue_order_index(ids)

    do_fetch_issue_states_page(
      ids,
      scope,
      assignee_filter,
      required_comment,
      required_labels,
      graphql_fun,
      [],
      issue_order_index
    )
  end

  defp do_fetch_issue_states_page(
         [],
         _scope,
         _assignee_filter,
         _required_comment,
         _required_labels,
         _graphql_fun,
         acc_issues,
         issue_order_index
       ) do
    acc_issues
    |> finalize_paginated_issues()
    |> sort_issues_by_requested_ids(issue_order_index)
    |> then(&{:ok, &1})
  end

  defp do_fetch_issue_states_page(
         ids,
         scope,
         assignee_filter,
         required_comment,
         required_labels,
         graphql_fun,
         acc_issues,
         issue_order_index
       ) do
    {batch_ids, rest_ids} = Enum.split(ids, @issue_page_size)

    {query, variables} =
      scope_query(
        scope,
        @project_query_by_ids,
        @team_query_by_ids,
        %{
          ids: batch_ids,
          first: length(batch_ids),
          relationFirst: @issue_page_size
        }
      )

    case graphql_fun.(query, variables) do
      {:ok, body} ->
        with {:ok, issues} <- decode_linear_response_strict(body, assignee_filter),
             {:ok, issues} <-
               apply_required_comment_gate(
                 issues,
                 required_comment,
                 required_labels,
                 assignee_filter,
                 graphql_fun
               ) do
          updated_acc = prepend_page_issues(issues, acc_issues)

          do_fetch_issue_states_page(
            rest_ids,
            scope,
            assignee_filter,
            required_comment,
            required_labels,
            graphql_fun,
            updated_acc,
            issue_order_index
          )
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp scope_query({:project, project_slug}, project_query, _team_query, variables)
       when is_binary(project_slug) do
    {project_query, Map.put(variables, :projectSlug, String.trim(project_slug))}
  end

  defp scope_query({:team, team_key}, _project_query, team_query, variables)
       when is_binary(team_key) do
    {team_query, Map.put(variables, :teamKey, String.trim(team_key))}
  end

  defp required_comment_for_fetch(required_comment, opts) do
    if Keyword.get(opts, :apply_required_comment, true), do: required_comment, else: nil
  end

  defp apply_required_comment_gate(
         issues,
         required_comment,
         _required_labels,
         _assignee_filter,
         _graphql_fun
       )
       when required_comment in [nil, ""] do
    {:ok, issues}
  end

  defp apply_required_comment_gate(
         _issues,
         required_comment,
         _required_labels,
         nil,
         _graphql_fun
       )
       when is_binary(required_comment) do
    {:error, :linear_required_comment_requires_assignee}
  end

  defp apply_required_comment_gate(
         issues,
         required_comment,
         required_labels,
         %{match_values: match_values},
         graphql_fun
       )
       when is_list(issues) and is_binary(required_comment) and is_list(required_labels) and
              is_struct(match_values, MapSet) do
    expected_body = String.trim(required_comment)

    Enum.reduce_while(
      issues,
      {:ok, []},
      &gate_issue(
        &1,
        &2,
        required_labels,
        expected_body,
        match_values,
        graphql_fun
      )
    )
    |> case do
      {:ok, gated_issues} -> {:ok, Enum.reverse(gated_issues)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp gate_issue(
         issue,
         {:ok, acc},
         required_labels,
         expected_body,
         match_values,
         graphql_fun
       ) do
    case gate_issue(issue, required_labels, expected_body, match_values, graphql_fun) do
      {:ok, gated_issue} -> {:cont, {:ok, [gated_issue | acc]}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp gate_issue(issue, required_labels, expected_body, match_values, graphql_fun) do
    if Issue.routable?(issue, required_labels) do
      with {:ok, matches?} <-
             required_comment_match?(
               issue.id,
               expected_body,
               match_values,
               graphql_fun
             ) do
        {:ok, if(matches?, do: issue, else: %{issue | dispatchable: false})}
      end
    else
      {:ok, issue}
    end
  end

  defp required_comment_match?(issue_id, expected_body, match_values, graphql_fun) do
    required_comment_match?(
      issue_id,
      expected_body,
      match_values,
      graphql_fun,
      nil
    )
  end

  defp required_comment_match?(
         issue_id,
         expected_body,
         match_values,
         graphql_fun,
         after_cursor
       ) do
    with {:ok, body} <-
           graphql_fun.(@comments_query, %{
             issueId: issue_id,
             first: @comment_page_size,
             after: after_cursor
           }),
         {:ok, comments, page_info} <- decode_comment_page_response(body) do
      match_comment_page(
        comments,
        page_info,
        issue_id,
        expected_body,
        match_values,
        graphql_fun
      )
    end
  end

  defp match_comment_page(
         comments,
         page_info,
         issue_id,
         expected_body,
         match_values,
         graphql_fun
       ) do
    if matching_comment?(comments, expected_body, match_values) do
      {:ok, true}
    else
      continue_comment_pages(
        next_page_cursor(page_info),
        issue_id,
        expected_body,
        match_values,
        graphql_fun
      )
    end
  end

  defp continue_comment_pages(
         {:ok, next_cursor},
         issue_id,
         expected_body,
         match_values,
         graphql_fun
       ) do
    required_comment_match?(
      issue_id,
      expected_body,
      match_values,
      graphql_fun,
      next_cursor
    )
  end

  defp continue_comment_pages(:done, _issue_id, _expected_body, _match_values, _graphql_fun) do
    {:ok, false}
  end

  defp continue_comment_pages(
         {:error, reason},
         _issue_id,
         _expected_body,
         _match_values,
         _graphql_fun
       ) do
    {:error, reason}
  end

  defp decode_comment_page_response(%{
         "data" => %{
           "issue" => %{
             "comments" => %{
               "nodes" => nodes,
               "pageInfo" => %{
                 "hasNextPage" => has_next_page,
                 "endCursor" => end_cursor
               }
             }
           }
         }
       })
       when is_list(nodes) do
    {:ok, nodes, %{has_next_page: has_next_page == true, end_cursor: end_cursor}}
  end

  defp decode_comment_page_response(%{"errors" => errors}) do
    {:error, {:linear_graphql_errors, errors}}
  end

  defp decode_comment_page_response(_response), do: {:error, :linear_unknown_payload}

  defp matching_comment?(comments, expected_body, match_values)
       when is_list(comments) and is_struct(match_values, MapSet) do
    Enum.any?(comments, fn
      %{"body" => body, "user" => %{"id" => user_id}}
      when is_binary(body) and is_binary(user_id) ->
        String.trim(body) == expected_body and MapSet.member?(match_values, user_id)

      _ ->
        false
    end)
  end

  defp issue_order_index(ids) when is_list(ids) do
    ids
    |> Enum.with_index()
    |> Map.new()
  end

  defp sort_issues_by_requested_ids(issues, issue_order_index)
       when is_list(issues) and is_map(issue_order_index) do
    fallback_index = map_size(issue_order_index)

    Enum.sort_by(issues, fn
      %Issue{id: issue_id} -> Map.get(issue_order_index, issue_id, fallback_index)
      _ -> fallback_index
    end)
  end

  defp build_graphql_payload(query, variables, operation_name) do
    %{
      "query" => query,
      "variables" => variables
    }
    |> maybe_put_operation_name(operation_name)
  end

  defp maybe_put_operation_name(payload, operation_name) when is_binary(operation_name) do
    trimmed = String.trim(operation_name)

    if trimmed == "" do
      payload
    else
      Map.put(payload, "operationName", trimmed)
    end
  end

  defp maybe_put_operation_name(payload, _operation_name), do: payload

  defp linear_error_context(payload, response) when is_map(payload) do
    operation_name =
      case Map.get(payload, "operationName") do
        name when is_binary(name) and name != "" -> " operation=#{name}"
        _ -> ""
      end

    body =
      response
      |> Map.get(:body)
      |> summarize_error_body()

    operation_name <> " body=" <> body
  end

  defp summarize_error_body(body) when is_binary(body) do
    body
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> truncate_error_body()
    |> inspect()
  end

  defp summarize_error_body(body) do
    body
    |> inspect(limit: 20, printable_limit: @max_error_body_log_bytes)
    |> truncate_error_body()
  end

  defp truncate_error_body(body) when is_binary(body) do
    if byte_size(body) > @max_error_body_log_bytes do
      binary_part(body, 0, @max_error_body_log_bytes) <> "...<truncated>"
    else
      body
    end
  end

  defp graphql_headers(tracker_settings) do
    case tracker_settings.api_key do
      nil ->
        {:error, :missing_linear_api_token}

      token ->
        {:ok,
         [
           {"Authorization", token},
           {"Content-Type", "application/json"}
         ]}
    end
  end

  defp post_graphql_request(payload, headers, endpoint) do
    Req.post(endpoint,
      headers: headers,
      json: payload,
      connect_options: [timeout: 30_000]
    )
  end

  defp decode_linear_response(response, assignee_filter) do
    decode_linear_response(response, assignee_filter, :drop_malformed)
  end

  defp decode_linear_response_strict(response, assignee_filter) do
    decode_linear_response(response, assignee_filter, :error_on_malformed)
  end

  defp decode_linear_response(
         %{"data" => %{"issues" => %{"nodes" => nodes}}},
         assignee_filter,
         malformed_policy
       )
       when is_list(nodes) do
    issues =
      nodes
      |> Enum.map(&normalize_issue(&1, assignee_filter))

    malformed_count = Enum.count(issues, &is_nil/1)

    case {malformed_policy, malformed_count > 0} do
      {:error_on_malformed, true} ->
        {:error, :linear_unknown_payload}

      {:drop_malformed, true} ->
        Logger.warning("Dropping malformed Linear issue records count=#{malformed_count}")
        {:ok, Enum.reject(issues, &is_nil/1)}

      {:drop_malformed, false} ->
        {:ok, issues}

      {_, false} ->
        {:ok, issues}
    end
  end

  defp decode_linear_response(%{"errors" => errors}, _assignee_filter, _malformed_policy) do
    {:error, {:linear_graphql_errors, errors}}
  end

  defp decode_linear_response(_unknown, _assignee_filter, _malformed_policy) do
    {:error, :linear_unknown_payload}
  end

  defp decode_linear_page_response(
         %{
           "data" => %{
             "issues" => %{
               "nodes" => nodes,
               "pageInfo" => %{"hasNextPage" => has_next_page, "endCursor" => end_cursor}
             }
           }
         },
         assignee_filter
       ) do
    with {:ok, issues} <- decode_linear_response(%{"data" => %{"issues" => %{"nodes" => nodes}}}, assignee_filter) do
      {:ok, issues, %{has_next_page: has_next_page == true, end_cursor: end_cursor}}
    end
  end

  defp decode_linear_page_response(response, assignee_filter), do: decode_linear_response(response, assignee_filter)

  defp next_page_cursor(%{has_next_page: true, end_cursor: end_cursor})
       when is_binary(end_cursor) and byte_size(end_cursor) > 0 do
    {:ok, end_cursor}
  end

  defp next_page_cursor(%{has_next_page: true}), do: {:error, :linear_missing_end_cursor}
  defp next_page_cursor(_), do: :done

  defp normalize_issue(issue, assignee_filter) when is_map(issue) do
    state_name = get_in(issue, ["state", "name"])

    if Enum.all?([issue["id"], issue["identifier"], issue["title"], state_name], &present_string?/1) do
      assignee = issue["assignee"]
      blockers = extract_blockers(issue)

      %Issue{
        id: issue["id"],
        identifier: issue["identifier"],
        title: issue["title"],
        description: issue["description"],
        priority: parse_priority(issue["priority"]),
        state: state_name,
        branch_name: issue["branchName"],
        url: issue["url"],
        assignee_id: assignee_field(assignee, "id"),
        blocked_by: blockers,
        labels: extract_labels(issue),
        dispatchable: dispatchable?(state_name, blockers, assignee, assignee_filter),
        created_at: parse_datetime(issue["createdAt"]),
        updated_at: parse_datetime(issue["updatedAt"])
      }
    end
  end

  defp normalize_issue(_issue, _assignee_filter), do: nil

  defp assignee_field(%{} = assignee, field) when is_binary(field), do: assignee[field]
  defp assignee_field(_assignee, _field), do: nil

  defp dispatchable?(state_name, blockers, assignee, assignee_filter) do
    assigned_to_worker?(assignee, assignee_filter) and
      not blocked_before_dispatch?(state_name, blockers)
  end

  defp blocked_before_dispatch?(state_name, blockers)
       when is_binary(state_name) and is_list(blockers) do
    normalize_state_name(state_name) == "todo" and
      Enum.any?(blockers, fn
        %{state: blocker_state} when is_binary(blocker_state) ->
          not terminal_state?(blocker_state)

        _ ->
          true
      end)
  end

  defp blocked_before_dispatch?(_state_name, _blockers), do: false

  defp terminal_state?(state_name) when is_binary(state_name) do
    terminal_states =
      Config.settings!().tracker.terminal_states
      |> Enum.map(&normalize_state_name/1)
      |> MapSet.new()

    MapSet.member?(terminal_states, normalize_state_name(state_name))
  end

  defp normalize_state_name(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp assigned_to_worker?(_assignee, nil), do: true

  defp assigned_to_worker?(%{} = assignee, %{match_values: match_values})
       when is_struct(match_values, MapSet) do
    assignee
    |> assignee_id()
    |> then(fn
      nil -> false
      assignee_id -> MapSet.member?(match_values, assignee_id)
    end)
  end

  defp assigned_to_worker?(_assignee, _assignee_filter), do: false

  defp assignee_id(%{} = assignee), do: normalize_assignee_match_value(assignee["id"])

  defp routing_assignee_filter do
    case Config.settings!().tracker.assignee do
      nil ->
        {:ok, nil}

      assignee ->
        build_assignee_filter(assignee)
    end
  end

  defp configured_tracker_for_read do
    tracker = Config.settings!().tracker

    if is_nil(tracker.api_key), do: {:error, :missing_linear_api_token}, else: {:ok, tracker}
  end

  defp tracker_scope(tracker) do
    project_scope? = present_string?(tracker.project_slug)
    team_scope? = present_string?(tracker.team_key)

    case {project_scope?, team_scope?} do
      {true, false} -> {:ok, {:project, tracker.project_slug}}
      {false, true} -> {:ok, {:team, tracker.team_key}}
      {false, false} -> {:error, :missing_linear_project_slug_or_team_key}
      {true, true} -> {:error, :multiple_linear_scopes}
    end
  end

  defp build_test_assignee_filter(opts) do
    case Keyword.get(opts, :assignee) do
      nil -> {:ok, nil}
      assignee -> build_assignee_filter(assignee)
    end
  end

  defp build_assignee_filter(assignee) when is_binary(assignee) do
    case normalize_assignee_match_value(assignee) do
      nil ->
        {:ok, nil}

      "me" ->
        resolve_viewer_assignee_filter()

      normalized ->
        {:ok, %{configured_assignee: assignee, match_values: MapSet.new([normalized])}}
    end
  end

  defp resolve_viewer_assignee_filter do
    case graphql(@viewer_query, %{}) do
      {:ok, %{"data" => %{"viewer" => viewer}}} when is_map(viewer) ->
        case assignee_id(viewer) do
          nil ->
            {:error, :missing_linear_viewer_identity}

          viewer_id ->
            {:ok, %{configured_assignee: "me", match_values: MapSet.new([viewer_id])}}
        end

      {:ok, _body} ->
        {:error, :missing_linear_viewer_identity}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_assignee_match_value(value) when is_binary(value) do
    case value |> String.trim() do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_assignee_match_value(_value), do: nil

  defp extract_labels(%{"labels" => %{"nodes" => labels}}) when is_list(labels) do
    labels
    |> Enum.map(& &1["name"])
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&(String.trim(&1) |> String.downcase()))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp extract_labels(_), do: []

  defp extract_blockers(%{"inverseRelations" => %{"nodes" => inverse_relations}})
       when is_list(inverse_relations) do
    inverse_relations
    |> Enum.flat_map(fn
      %{"type" => relation_type, "issue" => blocker_issue}
      when is_binary(relation_type) and is_map(blocker_issue) ->
        if String.downcase(String.trim(relation_type)) == "blocks" do
          [
            %{
              id: blocker_issue["id"],
              identifier: blocker_issue["identifier"],
              state: get_in(blocker_issue, ["state", "name"])
            }
          ]
        else
          []
        end

      _ ->
        []
    end)
  end

  defp extract_blockers(_), do: []

  defp present_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_string?(_value), do: false

  defp parse_datetime(nil), do: nil

  defp parse_datetime(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_priority(priority) when is_integer(priority), do: priority
  defp parse_priority(_priority), do: nil
end
