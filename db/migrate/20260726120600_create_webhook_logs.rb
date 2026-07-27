class CreateWebhookLogs < ActiveRecord::Migration[8.1]
  # Operational visibility for ingestion, so a missing activity can be diagnosed
  # without digging through server logs. Every delivery attempt writes a row —
  # including rejected ones, which are the interesting case.
  def change
    create_table :webhook_logs do |t|
      t.string :endpoint, null: false
      t.string :status, null: false
      t.string :source_file

      # The activity or health metric this delivery created or updated, if any.
      t.references :record, polymorphic: true, null: true

      t.text :error_message
      t.string :payload_digest
      t.integer :duration_ms

      t.timestamps
    end

    add_index :webhook_logs, :created_at
    add_index :webhook_logs, :status
  end
end
