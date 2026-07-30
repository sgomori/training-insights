# The arithmetic shared by every aggregation in the tool layer.
#
# Small on purpose. It exists so that the two rules that matter — nils are never
# counted as zero, and an average is never reported without the sample size
# behind it — are implemented once instead of per tool.
module MetricMath
  extend self

  # Mean of the non-nil values, with the sample size that produced it. A bare
  # average with no count is not self-contained, and nils must never be counted
  # as zero.
  def mean_with_sample(values, precision: 2)
    present = values.compact
    return { value: nil, sample_size: 0 } if present.empty?

    { value: (present.sum.to_f / present.size).round(precision), sample_size: present.size }
  end

  def percent_change(from, to, precision: 1)
    return nil if from.nil? || to.nil? || from.zero?

    (((to - from) / from.to_f) * 100).round(precision)
  end

  # Linear-interpolated quantile, the definition NumPy and R use by default, so
  # a figure quoted from here matches what a reader would get elsewhere.
  def quantile(values, fraction)
    present = values.compact.sort
    return nil if present.empty?
    return present.first.to_f if present.size == 1

    position = (present.size - 1) * fraction
    lower = present[position.floor]
    upper = present[position.ceil]
    lower + ((upper - lower) * (position - position.floor))
  end

  # Population standard deviation, which is what Foster's monotony is defined
  # over: the seven days of a week are the whole population, not a sample drawn
  # from a larger one.
  def standard_deviation(values)
    present = values.compact
    return nil if present.size < 2

    mean = present.sum.to_f / present.size
    Math.sqrt(present.sum { |v| (v - mean)**2 } / present.size)
  end
end
