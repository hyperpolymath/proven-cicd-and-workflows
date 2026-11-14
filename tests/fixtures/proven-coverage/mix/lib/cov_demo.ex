# SPDX-License-Identifier: MPL-2.0
defmodule CovDemo do
  def clamp_add(a, b), do: min(a + b, 255)

  def describe(n) when n < 0, do: "negative"
  def describe(0), do: "zero"
  def describe(_), do: "positive"
end
