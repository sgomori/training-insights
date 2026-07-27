# An API key issued by the operator for an external MCP client.
#
# Only the digest is persisted. `generate!` returns the plaintext token once and
# it cannot be recovered afterwards — a lost key is reissued, not looked up.
class ApiKey < ApplicationRecord
  TOKEN_BYTES = 32

  validates :name, presence: true
  validates :token_digest, presence: true, uniqueness: true

  scope :active, -> { where(revoked_at: nil) }

  # Returns the plaintext token. Display it once, then let it go.
  def self.generate!(name:)
    token = SecureRandom.urlsafe_base64(TOKEN_BYTES)
    create!(name: name, token_digest: digest(token))
    token
  end

  # Returns the matching active key, or nil. Comparison is against a digest of
  # the presented token, so no secret-dependent branch runs here.
  def self.authenticate(token)
    return nil if token.blank?

    active.find_by(token_digest: digest(token))
  end

  def self.digest(token)
    OpenSSL::Digest::SHA256.hexdigest(token)
  end

  def revoke!
    update!(revoked_at: Time.current)
  end

  def revoked?
    revoked_at.present?
  end
end
