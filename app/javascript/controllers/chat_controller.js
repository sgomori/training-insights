import { Controller } from "@hotwired/stimulus"

// Clears the composer once a turn has been appended, keeps the newest message
// in view, and gives up on a turn that never comes back.
//
// Deliberately small. The transcript is appended by Turbo Streams and the answer
// arrives over a broadcast, so nothing here fetches or renders — it does the
// three things the browser will not do on its own.
export default class extends Controller {
  static targets = ["input"]

  // Longer than a slow turn, short enough that a visitor is not left watching a
  // runner that will never stop.
  static ABANDON_AFTER_MS = 90000

  // The two class strings in failureBubble are copied from chats/_answer.html.erb
  // and have to move with it, or a failed turn renders in a stale palette.
  //
  // Kept in step with ChatJob::FAILED, which covers the same case from the other
  // side. This branch exists because that broadcast can miss: the job is
  // enqueued before the pending bubble's subscription is confirmed, so a turn
  // that fails in microseconds — a missing key, a DNS failure — answers a
  // channel nobody has joined yet. Without this the bubble spins forever, and a
  // misconfigured deployment looks like a hang rather than an error.
  static FAILED = "Something went wrong working that out. The training data is fine — try again in a moment."

  reset(event) {
    if (!event.detail.success) return

    this.inputTarget.value = ""
    this.scrollToLatest()
    this.watchLatestTurn()
  }

  scrollToLatest() {
    requestAnimationFrame(() => this.latestTurn()?.scrollIntoView({ behavior: "smooth", block: "nearest" }))
  }

  watchLatestTurn() {
    requestAnimationFrame(() => {
      const pending = this.latestTurn()
      if (!pending?.querySelector("turbo-cable-stream-source")) return

      const id = pending.id
      setTimeout(() => {
        // Still the same element, so the answer never replaced it.
        const stranded = document.getElementById(id)
        if (!stranded?.querySelector("turbo-cable-stream-source")) return

        stranded.replaceWith(this.failureBubble(id))
      }, this.constructor.ABANDON_AFTER_MS)
    })
  }

  failureBubble(id) {
    const article = document.createElement("article")
    article.id = id
    article.className = "space-y-4 text-stone-300"

    const paragraph = document.createElement("p")
    paragraph.className = "text-[1.0625rem] leading-7"
    paragraph.textContent = this.constructor.FAILED
    article.appendChild(paragraph)

    return article
  }

  latestTurn() {
    return document.getElementById("transcript")?.lastElementChild
  }
}
