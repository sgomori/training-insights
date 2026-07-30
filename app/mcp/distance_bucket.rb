# The distance categories the tools group efforts into, defined once.
#
# Two tools need them and need them to agree: a personal record at "10k" and a
# pace progression filtered to "10k" have to be drawn from the same set of runs,
# or the two responses contradict each other.
#
# Standard race distances carry a tolerance because a watch never measures the
# nominal figure. A 10k race comes back as 10.04km on a good day and 9.87km on a
# bad GPS day, and both are the same effort. Descriptive bands are for grouping
# training runs, where there is no nominal distance to be near.
module DistanceBucket
  Bucket = Struct.new(:key, :label, :nominal_km, :min_km, :max_km, :standard, keyword_init: true) do
    # A standard bucket is a tolerance window around a nominal distance, and both
    # of its edges belong to it: exactly 5.5km is within tolerance of a 5k. The
    # descriptive bands are a partition instead, so their upper bound is
    # exclusive and a 15.0km run lands in exactly one of them.
    def covers?(distance_meters)
      return false if distance_meters.nil?

      km = distance_meters / 1000.0
      return false if min_km && km < min_km
      return true if max_km.nil?

      standard? ? km <= max_km : km < max_km
    end

    def standard? = standard

    # A nil bound is unbounded and is omitted rather than sent as a null or an
    # infinity — JSON has no representation for the latter.
    def to_h
      {
        key: key,
        label: label,
        nominal_distance_km: nominal_km,
        min_distance_km: min_km,
        max_distance_km: max_km
      }.compact
    end
  end

  # Race distances, with the tolerance a GPS-measured effort needs to be
  # recognised as one of them.
  STANDARD = [
    Bucket.new(key: "5k", label: "5 kilometres", nominal_km: 5.0, min_km: 4.5, max_km: 5.5, standard: true),
    Bucket.new(key: "10k", label: "10 kilometres", nominal_km: 10.0, min_km: 9.0, max_km: 11.0, standard: true),
    Bucket.new(key: "half", label: "half marathon", nominal_km: 21.1, min_km: 20.0, max_km: 22.0, standard: true),
    Bucket.new(key: "marathon", label: "marathon", nominal_km: 42.2, min_km: 40.0, max_km: 44.5, standard: true)
  ].freeze

  # Descriptive bands for training runs. Contiguous and exhaustive, so every run
  # with a distance falls in exactly one.
  DESCRIPTIVE = [
    Bucket.new(key: "short", label: "short runs (under 7km)", min_km: 0.0, max_km: 7.0, standard: false),
    Bucket.new(key: "medium", label: "medium runs (7-15km)", min_km: 7.0, max_km: 15.0, standard: false),
    Bucket.new(key: "long", label: "long runs (15-25km)", min_km: 15.0, max_km: 25.0, standard: false),
    Bucket.new(key: "very_long", label: "very long runs (over 25km)", min_km: 25.0, max_km: nil, standard: false)
  ].freeze

  ALL = (STANDARD + DESCRIPTIVE).freeze
  KEYS = ALL.map(&:key).freeze

  def self.find(key) = ALL.find { |bucket| bucket.key == key.to_s }

  def self.standard = STANDARD

  # Which descriptive band a distance falls in, or nil when there is no distance.
  def self.describe(distance_meters)
    DESCRIPTIVE.find { |bucket| bucket.covers?(distance_meters) }
  end
end
