# SPDX-License-Identifier: MPL-2.0
# coverdata-to-lcov.exs [--tools-version] | IN.coverdata OUT.lcov
#
# Run inside a consumer Mix project, after `mix test --cover --export-coverage NAME`:
#
#   MIX_ENV=test mix run --no-start scripts/coverdata-to-lcov.exs cover/raw.coverdata cov/raw/elixir.lcov
#
# It imports the Erlang `:cover` data Mix exported and writes line coverage as
# LCOV. The consumer's mix.exs is not changed and this script is not a
# dependency of it.
#
# This is a self-contained equivalent of Hypatia.Coverage.CoverExport
# (hypatia#1107). It does not call Hypatia, because that would make Hypatia a
# dependency of every consumer. The rules are the same:
#   * line 0 is generated code and is dropped;
#   * only lines `:cover` reports appear (a line with 0 calls is executable and
#     not run);
#   * several modules in one source file are merged, summing calls per line;
#   * a module with no known source is skipped, never guessed;
#   * paths are made relative to the current directory;
#   * no BRDA, BRF or BRH is written: `:cover` has no branch data;
#   * output is sorted by path and line, so it is deterministic.
# Keep the two in step when Hypatia's changes.
#
# Exit: 0 written, 1 unreadable input or no source-mapped module.
defmodule ProvenCoverdataToLcov do
  @compile {:no_warn_undefined, :cover}

  def main(["--tools-version"]) do
    Mix.ensure_application!(:tools)
    _ = Application.load(:tools)
    IO.puts(to_string(Application.spec(:tools, :vsn)))
  end

  def main([input, output]) do
    Mix.ensure_application!(:tools)
    {:ok, _pid} = ensure_cover()

    case :cover.import(String.to_charlist(input)) do
      :ok -> :ok
      {:error, reason} -> fail("cannot import #{input}: #{inspect(reason)}")
    end

    modules = :cover.imported_modules()

    lcov =
      modules
      |> Enum.reduce(%{}, fn mod, acc ->
        with path when is_binary(path) <- source(mod),
             {:ok, entries} <- :cover.analyse(mod, :calls, :line) do
          Enum.reduce(entries, acc, fn
            {{_m, line}, calls}, acc when is_integer(line) and line > 0 and calls >= 0 ->
              Map.update(acc, path, %{line => calls}, fn lines ->
                Map.update(lines, line, calls, &(&1 + calls))
              end)

            _other, acc ->
              acc
          end)
        else
          _ -> acc
        end
      end)
      |> render()

    if lcov == "", do: fail("no module in #{input} maps to a source file")
    File.mkdir_p!(Path.dirname(output))
    File.write!(output, lcov)
    IO.puts("wrote #{output}")
  end

  def main(_), do: fail("usage: coverdata-to-lcov.exs IN.coverdata OUT.lcov")

  defp ensure_cover do
    case :cover.start() do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
    end
  end

  defp render(files) do
    files
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {path, lines} ->
      sorted = Enum.sort(lines)
      hit = Enum.count(sorted, fn {_, h} -> h > 0 end)

      [
        "SF:", path, "\n",
        Enum.map(sorted, fn {l, h} -> "DA:#{l},#{h}\n" end),
        "LF:#{length(sorted)}\n",
        "LH:#{hit}\n",
        "end_of_record\n"
      ]
    end)
    |> IO.iodata_to_binary()
  end

  # The source a module was compiled from, relative to the project. The module
  # is loaded from the project's own build, so its compile info names it.
  defp source(mod) do
    case Code.ensure_loaded(mod) do
      {:module, _} ->
        case mod.module_info(:compile)[:source] do
          src when is_list(src) -> relative(List.to_string(src))
          src when is_binary(src) -> relative(src)
          _ -> nil
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp relative(path) do
    root = String.trim_trailing(File.cwd!(), "/") <> "/"
    String.replace_prefix(path, root, "")
  end

  defp fail(message) do
    IO.puts(:stderr, "coverdata-to-lcov: " <> message)
    System.halt(1)
  end
end

ProvenCoverdataToLcov.main(System.argv())
