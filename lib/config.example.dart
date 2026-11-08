// Template for lib/config.dart. This example file is safe to commit.
//
// Setup:
//   1. Copy this file to lib/config.dart (same folder).
//   2. Replace the placeholder below with your own Roboflow API key.
//   3. Never commit lib/config.dart: it is listed in .gitignore.
//
// The app (lib/main.dart) reads `roboflowApiKey` and sends it as a Bearer
// token to the hosted Roboflow models. Hosted inference uses credits from
// your Roboflow plan. If the key is wrong or the credits run out, the app
// says "Detection offline" instead of silently seeing nothing.
//
// Use a key with only the access you need, and rotate it if it is ever
// pasted into a chat, a log or a screenshot.

const String roboflowApiKey = 'YOUR_ROBOFLOW_API_KEY_HERE';
