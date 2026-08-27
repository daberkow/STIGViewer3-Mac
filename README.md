# STIGViewer3-Mac
A repackaging of STIG Viewer 3 for Linux with needed Mac dependencies. The app is a Node.JS native app, and is just missing a sqlite driver.

> [!WARNING]
> I am making no claim to rights to the application, I could not find a LICENSE file other than the default Node license for the application, and I wanted to help those who need STIG Viewer 3 on the Mac. I hope this helps build an official Mac version.

Releases are in the [repo](https://github.com/daberkow/STIGViewer3-Mac/releases)!

## Process

I get the Linux version from cyber.mil, extract the files for the application, add the sqlite driver for Mac, then create a .app and sign it.

## Security Note

The application relies on an outdated version of a SQLite driver, thats why it wasn't working on the Mac before. I have patched it with a more up to date Mac driver here, the issue is that [repo](https://github.com/TryGhost/node-sqlite3) is now marked archived. The app also comes with other out of date dependencies, so we will call it ok. This is a locally run application, thus the security risk is minimal.
