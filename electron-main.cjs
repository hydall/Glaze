const { app, BrowserWindow, ipcMain } = require('electron');
const path = require('path');
const http = require('http');

let mainWindow;
let oauthServer = null;

function createWindow() {
  mainWindow = new BrowserWindow({
    width: 1024,
    height: 768,
    autoHideMenuBar: true,
    icon: path.join(__dirname, 'assets', 'logo.png'),
    webPreferences: {
      nodeIntegration: true,
      contextIsolation: false
    }
  });

  mainWindow.setMenuBarVisibility(false);
  mainWindow.loadFile(path.join(__dirname, 'dist', 'index.html'));
}

ipcMain.handle('oauth-start-server', () => {
    return new Promise((resolve, reject) => {
        if (oauthServer) {
            oauthServer.close();
            oauthServer = null;
        }

        oauthServer = http.createServer((req, res) => {
            const url = new URL(req.url, 'http://127.0.0.1');
            const code = url.searchParams.get('code');
            const state = url.searchParams.get('state');
            const error = url.searchParams.get('error');

            res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
            res.end('<!DOCTYPE html><html><body style="font-family:sans-serif;text-align:center;margin-top:40%"><p>Authorization successful! You can close this tab.</p></body></html>');

            if (mainWindow) {
                mainWindow.webContents.send('oauth-callback', { code, state, error });
            }

            oauthServer.close();
            oauthServer = null;
        });

        oauthServer.listen(0, '127.0.0.1', () => {
            resolve(oauthServer.address().port);
        });

        oauthServer.on('error', reject);
    });
});

ipcMain.handle('oauth-cancel-server', () => {
    if (oauthServer) {
        oauthServer.close();
        oauthServer = null;
    }
});

app.whenReady().then(() => {
  createWindow();

  app.on('activate', function () {
    if (BrowserWindow.getAllWindows().length === 0) createWindow();
  });
});

app.on('window-all-closed', function () {
  if (process.platform !== 'darwin') app.quit();
});
