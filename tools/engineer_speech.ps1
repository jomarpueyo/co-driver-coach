# Speech helper for tools/engineer.py: Windows offline dictation (push-to-talk) and text-to-speech.
# Reads one command per line on stdin and answers one line on stdout:
#   listen          start listening to the default microphone         -> OK | ERR <reason>
#   stop            stop and return what was heard                     -> TEXT <words>
#   say <text>      speak (queued)                                     -> OK
#   quiet           stop speaking                                      -> OK
#   rate <-10..10>  speaking rate                                      -> OK
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File engineer_speech.ps1 <phrases.txt>
param([string]$PhraseFile = "")

Add-Type -AssemblyName System.Speech
Add-Type -ReferencedAssemblies System.Speech -TypeDefinition @"
using System;
using System.Text;
using System.Threading;
using System.Speech.Recognition;
using System.Speech.Synthesis;

public class CdcSpeech {
  SpeechRecognitionEngine rec;
  SpeechSynthesizer tts = new SpeechSynthesizer();
  StringBuilder heard = new StringBuilder();
  ManualResetEvent done = new ManualResetEvent(true);
  bool listening = false;
  public bool HasMic = true;
  public string MicError = "";

  public CdcSpeech(string[] phrases) {
    rec = new SpeechRecognitionEngine(new System.Globalization.CultureInfo("en-US"));
    rec.LoadGrammar(new DictationGrammar());
    if (phrases.Length > 0) {
      // the questions drivers actually ask: these win over free dictation when they fit
      Grammar g = new Grammar(new GrammarBuilder(new Choices(phrases)));
      g.Name = "domain";
      g.Priority = 10;
      g.Weight = 1.0f;
      rec.LoadGrammar(g);
    }
    try { rec.SetInputToDefaultAudioDevice(); } catch (Exception e) { HasMic = false; MicError = e.Message; }
    rec.SpeechRecognized += (s, e) => {
      if (e.Result != null && e.Result.Confidence > 0.15) {
        lock (heard) { if (heard.Length > 0) heard.Append(" "); heard.Append(e.Result.Text); }
      }
    };
    rec.RecognizeCompleted += (s, e) => { listening = false; done.Set(); };
    try { tts.SelectVoiceByHints(VoiceGender.Female, VoiceAge.Adult); } catch { }
    tts.SetOutputToDefaultAudioDevice();
    tts.Rate = 1;
  }

  public string Listen() {
    if (!HasMic) return "ERR no microphone: " + MicError;
    if (listening) return "OK";
    lock (heard) heard.Clear();
    done.Reset();
    listening = true;
    rec.RecognizeAsync(RecognizeMode.Multiple);
    return "OK";
  }

  public string Stop() {
    if (listening) {
      rec.RecognizeAsyncStop(); // finishes the phrase in progress first
      done.WaitOne(5000);
    }
    lock (heard) return heard.ToString();
  }

  public void Say(string text) { tts.SpeakAsync(text); }
  public void Quiet() { tts.SpeakAsyncCancelAll(); }
  public void Rate(int r) { tts.Rate = Math.Max(-10, Math.Min(10, r)); }
}
"@

$phrases = @()
if ($PhraseFile -and (Test-Path $PhraseFile)) { $phrases = @(Get-Content $PhraseFile | Where-Object { $_.Trim() -ne "" }) }
$sp = New-Object CdcSpeech (, [string[]]$phrases)
[Console]::Out.WriteLine("READY mic=" + $sp.HasMic + " " + $sp.MicError)
[Console]::Out.Flush()

while (($line = [Console]::In.ReadLine()) -ne $null) {
  $out = "OK"
  try {
    if ($line -eq "listen") { $out = $sp.Listen() }
    elseif ($line -eq "stop") { $out = "TEXT " + $sp.Stop() }
    elseif ($line.StartsWith("say ")) { $sp.Say($line.Substring(4)) }
    elseif ($line -eq "quiet") { $sp.Quiet() }
    elseif ($line.StartsWith("rate ")) { $sp.Rate([int]$line.Substring(5)) }
    elseif ($line -eq "exit") { break }
    else { $out = "ERR unknown command" }
  } catch { $out = "ERR " + $_.Exception.Message }
  [Console]::Out.WriteLine($out)
  [Console]::Out.Flush()
}
