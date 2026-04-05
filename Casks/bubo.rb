cask "bubo" do
  version "1.9.78"
  sha256 "ebab7a7df00871b0ca2ec4c5328be0eb0297a58fff886b1ea09c5eb54f3eefca"

  url "https://github.com/avpv/bubo/releases/download/v#{version}/Bubo.dmg"
  name "Bubo"
  desc "Menu bar calendar with full-screen meeting alerts and Pomodoro timer"
  homepage "https://github.com/avpv/bubo"

  depends_on macos: ">= :ventura"

  app "Bubo.app"

  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-cr", "#{appdir}/Bubo.app"]
  end

  zap trash: [
    "~/Library/Preferences/com.avpv.Bubo.plist",
    "~/Library/Application Support/com.avpv.Bubo",
  ]
end
