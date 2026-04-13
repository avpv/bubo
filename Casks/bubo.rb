cask "bubo" do
  version "1.10.27"
  sha256 "30e9b2040a316c893f1339ca22b6148bc8f809d442c82311724477677178a7a6"

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
