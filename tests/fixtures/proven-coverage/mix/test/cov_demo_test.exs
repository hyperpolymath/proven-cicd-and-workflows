# SPDX-License-Identifier: MPL-2.0
defmodule CovDemoTest do
  use ExUnit.Case

  test "describe zero" do
    assert CovDemo.describe(0) == "zero"
  end

  @tag :proven
  test "clamp_add never exceeds 255" do
    for a <- 0..255, do: assert(CovDemo.clamp_add(a, 255) <= 255)
  end
end
