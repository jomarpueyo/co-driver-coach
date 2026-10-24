# Recognize each chunk as one utterance (up to 8 phrases) and write phrase timings
# relative to the chunk; chunk.py's index gives each chunk's offset in the recording.
Add-Type -AssemblyName System.Speech
$work = if ($env:CDC_VOICE_WORK) { $env:CDC_VOICE_WORK } else { Join-Path $env:TEMP 'cdc_tests' }
$dir = Join-Path $work 'chunks'
$phrases = @(Get-Content (Join-Path $work 'phrases.txt') | Where-Object { $_.Trim() -ne '' } | ForEach-Object { [string]$_ })
$culture = New-Object System.Globalization.CultureInfo('en-US')
$engine = New-Object System.Speech.Recognition.SpeechRecognitionEngine($culture)
$choices = New-Object System.Speech.Recognition.Choices
foreach ($p in $phrases) { [void]$choices.Add($p) }
$gb = New-Object System.Speech.Recognition.GrammarBuilder
$gb.Culture = $culture
$gb.Append($choices, 1, 8)
$engine.LoadGrammar((New-Object System.Speech.Recognition.Grammar($gb)))
$engine.EndSilenceTimeout = [TimeSpan]::FromMilliseconds(1500)          # whole chunk = one utterance
$engine.EndSilenceTimeoutAmbiguous = [TimeSpan]::FromMilliseconds(1500)
$sorted = $phrases | Sort-Object { -($_.Split(' ').Count) }

$all = New-Object System.Collections.ArrayList
foreach ($f in Get-ChildItem $dir -Filter '*.wav' | Sort-Object Name) {
  $engine.SetInputToWaveFile($f.FullName)
  $r = $engine.Recognize()
  if (-not $r) { [void]$all.Add([ordered]@{ file = $f.Name; phrase = $null; start = 0; dur = 0; conf = 0 }); continue }
  $words = @($r.Words | ForEach-Object { $_.Text })
  $i = 0
  while ($i -lt $words.Count) {
    $matched = $false
    foreach ($p in $sorted) {
      $pw = $p.Split(' ')
      if ($i + $pw.Count -le $words.Count -and (($words[$i..($i + $pw.Count - 1)]) -join ' ') -eq $p) {
        $a = $r.GetAudioForWordRange($r.Words[$i], $r.Words[$i + $pw.Count - 1])
        [void]$all.Add([ordered]@{ file = $f.Name; phrase = [string]$p; start = [math]::Round($a.AudioPosition.TotalSeconds, 3);
                                  dur = [math]::Round($a.Duration.TotalSeconds, 3); conf = [math]::Round($r.Confidence, 2) })
        $i += $pw.Count; $matched = $true; break
      }
    }
    if (-not $matched) { $i++ }
  }
}
$engine.Dispose()
ConvertTo-Json @($all) -Depth 4 | Out-File -Encoding utf8 (Join-Path $dir 'recognized.json')
"{0} phrases from {1} chunks" -f ($all | Where-Object { $_.phrase }).Count, (Get-ChildItem $dir -Filter '*.wav').Count
