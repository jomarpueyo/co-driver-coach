# Recognize each final clip on its own (one phrase) and compare with its script line.
Add-Type -AssemblyName System.Speech
$work = if ($env:CDC_VOICE_WORK) { $env:CDC_VOICE_WORK } else { Join-Path $env:TEMP 'cdc_tests' }
$phrases = @(Get-Content (Join-Path $work 'phrases.txt') | Where-Object { $_.Trim() -ne '' } | ForEach-Object { [string]$_ })
$culture = New-Object System.Globalization.CultureInfo('en-US')
$engine = New-Object System.Speech.Recognition.SpeechRecognitionEngine($culture)
$choices = New-Object System.Speech.Recognition.Choices
foreach ($p in $phrases) { [void]$choices.Add($p) }
$gb = New-Object System.Speech.Recognition.GrammarBuilder
$gb.Culture = $culture
$gb.Append($choices)
$engine.LoadGrammar((New-Object System.Speech.Recognition.Grammar($gb)))
$ok = 0; $n = 0; $diff = @()
foreach ($f in Get-ChildItem (Join-Path $work 'voice_check3') -Filter '*.wav' | Sort-Object Name) {
  $n++
  $expected = $phrases[[int]$f.BaseName - 1]
  $engine.SetInputToWaveFile($f.FullName)
  $r = $engine.Recognize()
  $heard = if ($r) { $r.Text } else { '(nothing)' }
  if ($heard -eq $expected) { $ok++ } else { $diff += ('{0,3} {1,-30} heard: {2}' -f $f.BaseName, $expected, $heard) }
}
$engine.Dispose()
"$ok of $n clips recognized as their script line"
'Not matched:'
$diff
