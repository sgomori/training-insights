class CreateApiKeys < ActiveRecord::Migration[8.1]
  # Keys issued by the operator for external MCP clients. Only the digest is
  # stored — a key is displayed once at generation and cannot be recovered.
  def change
    create_table :api_keys do |t|
      t.string :name, null: false
      t.string :token_digest, null: false
      t.datetime :last_used_at
      t.datetime :revoked_at

      t.timestamps
    end

    add_index :api_keys, :token_digest, unique: true
  end
end
