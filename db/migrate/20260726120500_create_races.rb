class CreateRaces < ActiveRecord::Migration[8.1]
  def change
    create_table :races do |t|
      t.string :name, null: false
      t.date :race_date, null: false
      t.integer :distance_meters, null: false

      # Both in seconds. Target is set beforehand, result afterwards.
      t.integer :target_time_seconds
      t.integer :result_time_seconds

      t.string :status, null: false, default: "upcoming"
      t.text :notes

      t.timestamps
    end

    add_index :races, :race_date
    add_index :races, :status
  end
end
