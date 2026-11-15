Pod::Spec.new do |s|
  s.name             = 'audio_service'
  s.version          = '0.0.1'
  s.summary          = 'Flutter plugin to play audio in the background while the screen is off.'
  s.description      = <<-DESC
Flutter plugin to play audio in the background while the screen is off.
Backing the forked audio_service (lib/audio_service.dart identical to
audio_service 0.18.19). The iOS/darwin side (MPNowPlayingInfoCenter lock-screen
card, AVAudioSession activation, MediaPlayer controls) is supplied verbatim
from the upstream darwin/ directory; source kept inside packages/audio_service/ios/.
                       DESC
  s.homepage         = 'https://github.com/ryanheise/audio_service'
  s.license          = { :type => 'MIT' }
  s.author           = { 'Ryan Heise' => 'ryan@ryanheise.com' }
  s.source           = { :path => '.' }
  s.source_files = 'audio_service/Sources/audio_service/**/*.{h,m}'
  s.public_header_files = 'audio_service/Sources/audio_service/include/**/*.h'
  s.ios.dependency 'Flutter'
  s.ios.deployment_target = '12.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end