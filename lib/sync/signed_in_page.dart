/// The page the browser shows once Google sign-in hands control back to the
/// app (served by the loopback server on localhost). It is fixed before
/// sign-in starts, so it cannot name the account.
const signedInPage = r'''<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Signed in · ShelfSync</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link href="https://fonts.googleapis.com/css2?family=Figtree:wght@400;600;700&family=Literata:opsz,wght@7..72,600&display=swap" rel="stylesheet">
<style>
  * { box-sizing: border-box; }
  body {
    margin: 0; min-height: 100vh; display: flex; align-items: center; justify-content: center;
    padding: 48px 24px; background: #F6F5F1; color: #1D2321;
    font-family: Figtree, system-ui, sans-serif;
  }
  a { color: #00796B; } a:hover { color: #004D40; }
  .card {
    width: 100%; max-width: 520px; border-radius: 24px; background: #FFFFFF;
    box-shadow: 0 1px 2px rgba(0,0,0,0.04), 0 16px 48px rgba(0,0,0,0.08);
    padding: 40px 40px 32px; display: flex; flex-direction: column; align-items: center; gap: 22px;
    text-align: center;
  }
  .logo { position: relative; width: 72px; height: 72px; }
  .shelf {
    width: 72px; height: 72px; border-radius: 18px; background: #263238;
    display: flex; align-items: flex-end; justify-content: center; gap: 4px; padding-bottom: 16px;
  }
  .shelf span { border-radius: 2px; }
  .badge {
    position: absolute; right: -10px; bottom: -10px; width: 34px; height: 34px; border-radius: 17px;
    background: #00897B; border: 3px solid #FFFFFF; display: flex; align-items: center; justify-content: center;
  }
  .intro { display: flex; flex-direction: column; gap: 10px; }
  h1 { margin: 0; font-family: Literata, Georgia, serif; font-size: 32px; font-weight: 600; }
  .intro p { margin: 0; font-size: 17px; line-height: 1.5; color: #5B6764; }
  .next {
    width: 100%; border-radius: 16px; background: #F6F5F1; padding: 18px 20px;
    display: flex; flex-direction: column; gap: 14px; text-align: left;
  }
  .label { font-size: 12px; font-weight: 600; letter-spacing: 1px; text-transform: uppercase; color: #8A9A96; }
  .step { display: flex; gap: 14px; align-items: flex-start; }
  .step b {
    width: 26px; height: 26px; flex-shrink: 0; border-radius: 13px; background: #E0F2F1; color: #00695C;
    font-size: 14px; font-weight: 700; display: flex; align-items: center; justify-content: center;
  }
  .step span { font-size: 15px; line-height: 1.45; padding-top: 3px; }
  .privacy { display: flex; gap: 10px; align-items: center; color: #5B6764; font-size: 14px; line-height: 1.45; text-align: left; }
  .privacy svg { flex-shrink: 0; }
  hr { width: 100%; height: 1px; margin: 0; border: 0; background: #E6EAE8; }
  footer { font-size: 13px; color: #8A9A96; }
  @media (max-width: 480px) { .card { padding: 32px 22px 26px; } h1 { font-size: 28px; } }
</style>
</head>
<body>
<main class="card">
  <div class="logo" aria-hidden="true">
    <div class="shelf">
      <span style="width: 10px; height: 30px; background: #EF5350"></span>
      <span style="width: 8px; height: 36px; background: #FFCA28"></span>
      <span style="width: 10px; height: 26px; background: #66BB6A"></span>
      <span style="width: 8px; height: 34px; background: #42A5F5"></span>
    </div>
    <div class="badge">
      <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="#FFFFFF" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"><path d="M5 12.5l4.5 4.5L19 7.5"></path></svg>
    </div>
  </div>

  <div class="intro">
    <h1>You’re signed in</h1>
    <p>ShelfSync is now connected to your Google Drive. You can close this tab and go back to the app.</p>
  </div>

  <section class="next">
    <span class="label">What happens next</span>
    <div class="step"><b>1</b><span>A ShelfSync folder appears in your Google Drive. Your books live there.</span></div>
    <div class="step"><b>2</b><span>Books you add on this PC upload to it, and your page is saved as you read.</span></div>
    <div class="step"><b>3</b><span>Sign in on your other devices with the same Google account to see them there.</span></div>
  </section>

  <div class="privacy">
    <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="5" y="11" width="14" height="9" rx="2"></rect><path d="M8 11V8a4 4 0 0 1 8 0v3"></path></svg>
    <span>ShelfSync only sees the files it creates, never the rest of your Drive.</span>
  </div>

  <hr>
  <footer>ShelfSync · <a href="https://thisara-g.github.io/shelfsync/privacy.html">Privacy</a> · <a href="https://github.com/thisara-g/shelfsync">Source on GitHub</a></footer>
</main>
</body>
</html>''';
