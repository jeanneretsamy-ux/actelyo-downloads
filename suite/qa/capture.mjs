import fs from 'node:fs';
import assert from 'node:assert/strict';

// Capture the actual Electron window rather than CDP Page.captureScreenshot,
// which can stall on a live OpenBousic renderer in a multi-app Windows session.
export async function captureWindow(instance, file) {
  const window = await instance.app.browserWindow(instance.page);
  try {
    const capture = await window.evaluate(async win => {
      if (win.isDestroyed()) throw Error('Window closed before capture');
      if (win.isMinimized()) win.restore();
      win.show();
      win.focus();
      let timer;
      try {
        const image = await Promise.race([
          win.webContents.capturePage(),
          new Promise((_, reject) => { timer = setTimeout(() => reject(Error('Native window capture timed out after 30 seconds')), 30000); })
        ]);
        if (image.isEmpty()) throw Error('Native window capture is empty');
        const size = image.getSize();
        const bitmap = image.toBitmap();
        const colors = new Set();
        const stride = Math.max(4, Math.floor(bitmap.length / 4096 / 4) * 4);
        for (let i = 0; i + 3 < bitmap.length; i += stride) colors.add(bitmap.readUInt32LE(i));
        return { ...size, colors: colors.size, png: image.toPNG().toString('base64') };
      } finally { clearTimeout(timer); }
    });
    assert(capture.width >= 200 && capture.height >= 200, 'Window capture is too small');
    assert(capture.colors >= 16, 'Window capture is blank or almost uniform');
    fs.writeFileSync(file, Buffer.from(capture.png, 'base64'));
    return { method: 'electron-webContents', width: capture.width, height: capture.height, colors: capture.colors };
  } finally { await window.dispose(); }
}
