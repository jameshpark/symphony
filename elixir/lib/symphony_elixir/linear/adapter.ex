defmodule SymphonyElixir.Linear.Adapter do
  @moduledoc """
  Linear-backed tracker adapter.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Linear.{AgentTool, Client}
  alias SymphonyElixir.Tracker.Issue

  @spec validate_config(map()) :: :ok | {:error, term()}
  def validate_config(tracker_settings) do
    with :ok <- validate_required_string(tracker_settings.endpoint, :invalid_linear_endpoint),
         :ok <- validate_required_string(tracker_settings.api_key, :missing_linear_api_token),
         :ok <- validate_scope(tracker_settings.project_slug, tracker_settings.team_key),
         :ok <- validate_optional_assignee(tracker_settings.assignee) do
      validate_required_comment(
        tracker_settings.required_comment,
        tracker_settings.assignee
      )
    end
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(states), do: client_module().fetch_issues_by_states(states)

  @spec fetch_issues_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_ids(issue_ids), do: client_module().fetch_issues_by_ids(issue_ids)

  @spec agent_tool_specs() :: [map()]
  def agent_tool_specs, do: AgentTool.tool_specs()

  @spec execute_agent_tool(String.t(), term(), keyword()) :: map()
  def execute_agent_tool(tool, arguments, opts) do
    AgentTool.execute(tool, arguments, opts)
  end

  @spec secret_environment_names(map()) :: [String.t()]
  def secret_environment_names(tracker_settings), do: tracker_settings.secret_environment_names

  defp client_module do
    Application.get_env(:symphony_elixir, :linear_client_module, Client)
  end

  defp validate_required_string(value, error) do
    if present_string?(value), do: :ok, else: {:error, error}
  end

  defp validate_scope(project_slug, team_key) do
    case {present_string?(project_slug), present_string?(team_key)} do
      {true, false} -> :ok
      {false, true} -> :ok
      {false, false} -> {:error, :missing_linear_project_slug_or_team_key}
      {true, true} -> {:error, :multiple_linear_scopes}
    end
  end

  defp validate_optional_assignee(nil), do: :ok

  defp validate_optional_assignee(assignee) do
    validate_required_string(assignee, :invalid_linear_assignee)
  end

  defp validate_required_comment(nil, _assignee), do: :ok

  defp validate_required_comment(required_comment, assignee) do
    with :ok <-
           validate_required_string(
             required_comment,
             :invalid_linear_required_comment
           ) do
      validate_required_string(
        assignee,
        :linear_required_comment_requires_assignee
      )
    end
  end

  defp present_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_string?(_value), do: false
end
