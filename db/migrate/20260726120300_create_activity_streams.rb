class CreateActivityStreams < ActiveRecord::Migration[8.1]
  # Time-series samples for one activity, stored as PostgreSQL array columns —
  # one row per activity rather than one row per sample. No MCP tool queries
  # *into* a stream; they aggregate whole streams, so arrays avoid hundreds of
  # thousands of rows for no analytical gain.
  #
  # There are deliberately no GPS columns. The pipeline strips position data
  # before delivery and this application promises it stores none, so the absence
  # of the column is the guarantee. Do not add one, even nullable, even unused.
  def change
    create_table :activity_streams do |t|
      t.references :activity, null: false, foreign_key: true, index: { unique: true }

      # Seconds between samples, as configured on the sending pipeline.
      t.integer :sample_rate_seconds

      t.integer :heart_rate, array: true
      t.integer :cadence, array: true
      t.float :enhanced_speed, array: true
      t.float :enhanced_altitude, array: true
      t.integer :power, array: true
      t.float :distance, array: true
      t.integer :temperature, array: true
      t.float :vertical_oscillation, array: true
      t.float :stance_time, array: true

      t.timestamps
    end
  end
end
