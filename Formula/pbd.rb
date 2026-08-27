# Homebrew formula for pbd — `brew install jeffreybaird/tap/pbd` once this is
# tapped, `brew install --HEAD ./Formula/pbd.rb` today.
#
# WHAT MAKES THIS INSTALLABLE. The whole tree goes into libexec unchanged —
# bin/, lib/, scripts/ and the template roots (infra-*/, app/, deploy/,
# app-template*/, gitea-host/) — and bin/pbd is symlinked onto the PATH from
# there. pbd follows that symlink to find its own directory, so the layout it
# sees inside libexec is the same one it sees in a checkout, and there is one
# code path rather than an "installed" one and a "development" one.
#
# Nothing is ever written back into the prefix: transcripts and cached
# credentials go to $XDG_STATE_HOME/pbd, and configuration is read from
# $XDG_CONFIG_HOME/pbd/env. `pbd config` prints all three paths.
class Pbd < Formula
  desc "Push-button deploy: one command provisions an app, its repo and its pipeline"
  homepage "https://github.com/jeffreybaird/push-button-deploy"
  license "MIT"

  head "https://github.com/jeffreybaird/push-button-deploy.git", branch: "main"

  # Filled in at the first tagged release:
  #
  #   url "https://github.com/jeffreybaird/push-button-deploy/archive/refs/tags/v0.1.0.tar.gz"
  #   sha256 "..."
  #   version "0.1.0"

  # What every run needs. Terraform is deliberately absent: it is BUSL-licensed
  # and no longer in homebrew-core, so it comes from hashicorp/tap (or OpenTofu)
  # and the caveat below says so rather than the formula failing to install.
  depends_on "gh"       # GitHub Actions: repo creation, secrets, run polling
  depends_on "jq"       # the Gitea provider's API parsing
  uses_from_macos "curl"
  uses_from_macos "git"

  def install
    libexec.install Dir["*"] - ["README.md", "DIRECTIONS.md", "Formula"]
    # The example config is documentation, not something to run: keep it where
    # `brew info` can point at it.
    pkgshare.install ".env.example"
    doc.install "README.md", "DIRECTIONS.md"

    # The command, and the deprecated entry points it replaced — a `pbd` on the
    # PATH resolves this symlink to libexec and finds its library beside it.
    bin.install_symlink libexec/"bin/pbd"
  end

  def caveats
    <<~EOS
      Terraform is required and is not in homebrew-core (BUSL). Install it with:

        brew tap hashicorp/tap && brew install hashicorp/tap/terraform

      Configuration — DigitalOcean, DNSimple and Spaces credentials, your DNS
      zone — goes in an env file. Start from the example:

        mkdir -p ~/.config/pbd
        cp #{opt_pkgshare}/.env.example ~/.config/pbd/env
        $EDITOR ~/.config/pbd/env

      Then check the machine before provisioning anything:

        pbd check ~/src/myapp

      `pbd config` prints where pbd found its templates, its state and that file.
    EOS
  end

  test do
    assert_match "pbd", shell_output("#{bin}/pbd --version")
    assert_match "Usage:", shell_output("#{bin}/pbd --help")
    # The install is only real if the command can reach its own library and
    # templates through the symlink.
    assert_match "pbd bootstrap", shell_output("#{bin}/pbd help bootstrap")
    assert_match libexec.to_s, shell_output("#{bin}/pbd config")
    assert_predicate libexec/"infra-persistent/main.tf", :exist?
    # A usage error is 2, not 1 — shell_output's second argument asserts it.
    assert_match "no such command", shell_output("#{bin}/pbd nonesuch 2>&1", 2)
  end
end
