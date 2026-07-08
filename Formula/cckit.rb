# Homebrew formula for cckit.
# Install (HEAD) once this lives in a tap (jeiemgi/homebrew-cckit):
#   brew tap jeiemgi/cckit && brew install --HEAD cckit
# This is a reference copy — the formula users actually install lives in the jeiemgi/homebrew-cckit
# tap and is bumped (with a freshly computed sha256) by the release-please publish job. release-please
# keeps the `version`/`url` lines here in sync via the trailing release-please annotations; the
# `sha256` is NOT recomputed here (the tag tarball doesn't exist until the release is cut), so treat
# the tap as authoritative for installs.
class Cckit < Formula
  desc "Project operating system for coding agents — the full GitHub work lifecycle as a CLI"
  homepage "https://cckit.dev"
  url "https://github.com/jeiemgi/cckit/archive/refs/tags/v0.5.0.tar.gz" # x-release-please-version
  sha256 "7976fc21edd2ed026dd3f5d4192f9919279f96f9b096a1fa305934dfe53dd282"
  version "0.5.0" # x-release-please-version
  license any_of: ["MIT", "Apache-2.0"]
  head "https://github.com/jeiemgi/cckit.git", branch: "main"

  depends_on "git"
  depends_on "jq" => :recommended

  def install
    # Ship the bash bundle + plugin assets under libexec; expose only the dispatcher on PATH.
    libexec.install Dir["*"]
    (bin/"cckit").write_env_script libexec/"bin/cckit", {}
    chmod 0755, libexec/"bin/cckit"
  end

  test do
    assert_match "cckit", shell_output("#{bin}/cckit version")
  end
end
