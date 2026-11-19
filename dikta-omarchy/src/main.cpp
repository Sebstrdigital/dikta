#include "backend.h"
#include "hotkey.h"
#include "theme.h"

#include <QCommandLineParser>
#include <QDir>
#include <QFile>
#include <QApplication>
#include <QIcon>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QLocalServer>
#include <QLocalSocket>
#include <QLockFile>
#include <QMenu>
#include <QPainter>
#include <QQmlComponent>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickStyle>
#include <QQuickWindow>
#include <QSaveFile>
#include <QSvgRenderer>
#include <QSystemTrayIcon>
#include <QTimer>
#include <cerrno>
#include <cstdio>
#include <sys/stat.h>
#include <unistd.h>

namespace {
QString runtimeDirectory()
{
    // A private, owned directory prevents another user replacing the socket or lock.
    const QString base = qEnvironmentVariable("XDG_RUNTIME_DIR", "/tmp");
    const QString path = base + "/dikta-" + QString::number(getuid());
    const QByteArray encoded = QFile::encodeName(path);
    if (::mkdir(encoded.constData(), 0700) != 0 && errno != EEXIST)
        return {};
    struct stat info {};
    if (::lstat(encoded.constData(), &info) != 0 || !S_ISDIR(info.st_mode)
        || info.st_uid != getuid() || (info.st_mode & 077) != 0)
        return {};
    return path;
}

enum class CommandResult { NoServer, Delivered, Failed };

bool validPanelAction(const QByteArray &action)
{
    return action == "toggle" || action == "show" || action == "hotkey"
        || action == "notifications" || action == "quit"
        || (action.size() == 6 && action.startsWith("copy:")
            && action.at(5) >= '0' && action.at(5) <= '4');
}

CommandResult sendCommand(const QString &socketPath, const QByteArray &command)
{
    QLocalSocket socket;
    socket.connectToServer(socketPath, QIODevice::ReadWrite);
    if (!socket.waitForConnected(1000))
        return CommandResult::NoServer;
    if (socket.write(command + '\n') < 0)
        return CommandResult::Failed;
    if (socket.bytesToWrite() && !socket.waitForBytesWritten(1000))
        return CommandResult::Failed;
    if (!socket.canReadLine() && !socket.waitForReadyRead(3000))
        return CommandResult::Failed;
    return socket.readLine() == "ok\n" ? CommandResult::Delivered : CommandResult::Failed;
}
}

int main(int argc, char *argv[])
{
    QApplication app(argc, argv);
    app.setApplicationName("dikta");
    app.setDesktopFileName("dikta");
    app.setQuitOnLastWindowClosed(false);

    QCommandLineParser parser;
    parser.setApplicationDescription("Offline dictation");
    parser.addHelpOption();
    QCommandLineOption toggleOption("toggle", "Toggle dictation without showing the window.");
    QCommandLineOption showOption("show", "Show the Dikta window.");
    QCommandLineOption backgroundOption("background", "Start in the background without recording.");
    QCommandLineOption panelActionOption("panel-action", "Send an action to the running Dikta instance.", "action");
    parser.addOption(toggleOption);
    parser.addOption(showOption);
    parser.addOption(backgroundOption);
    parser.addOption(panelActionOption);
    parser.process(app);
    if (int(parser.isSet(toggleOption)) + int(parser.isSet(showOption))
            + int(parser.isSet(backgroundOption)) + int(parser.isSet(panelActionOption)) > 1
        || !parser.positionalArguments().isEmpty()) {
        std::fputs("Use only one of --toggle, --show, --background or --panel-action.\n", stderr);
        return 1;
    }
    const bool toggle = parser.isSet(toggleOption);
    const bool background = parser.isSet(backgroundOption);
    const bool panelAction = parser.isSet(panelActionOption);
    const QByteArray command = panelAction ? parser.value(panelActionOption).toUtf8()
        : QByteArray(toggle ? "toggle" : (background ? "ping" : "show"));
    if (panelAction && !validPanelAction(command)) {
        std::fputs("Invalid panel action. Use toggle, show, hotkey, notifications, quit or copy:0 through copy:4.\n", stderr);
        return 1;
    }
    const QString directory = runtimeDirectory();
    if (directory.isEmpty()) {
        std::fputs("Cannot create a secure Dikta runtime directory.\n", stderr);
        return 1;
    }
    const QString socketPath = directory + "/control.sock";
    const CommandResult initial = sendCommand(socketPath, command);
    if (initial == CommandResult::Delivered)
        return 0;
    if (initial == CommandResult::Failed) {
        std::fputs("Dikta did not acknowledge the command.\n", stderr);
        return 1;
    }

    // Serialize startup and stale-socket removal. The lock is held for the
    // entire lifetime of the server, including while its window is hidden.
    QLockFile lock(directory + "/instance.lock");
    lock.setStaleLockTime(0);
    if (!lock.tryLock(3000)) {
        if (sendCommand(socketPath, command) == CommandResult::Delivered)
            return 0;
        std::fputs("Dikta is running but its control socket is unavailable.\n", stderr);
        return 1;
    }
    if (panelAction) {
        std::fputs("Dikta is not running.\n", stderr);
        return 1;
    }
    QLocalServer::removeServer(socketPath);
    QLocalServer server;
    server.setSocketOptions(QLocalServer::UserAccessOption);
    if (!server.listen(socketPath)) {
        std::fprintf(stderr, "Cannot start Dikta control socket: %s\n", qPrintable(server.errorString()));
        return 1;
    }

    QQuickStyle::setStyle("Material");
    Theme theme;
    Backend backend;
    Hotkey hotkey;
    hotkey.ensureDefault();
    QQmlApplicationEngine engine;
    engine.rootContext()->setContextProperty("theme", &theme);
    engine.rootContext()->setContextProperty("backend", &backend);
    engine.rootContext()->setContextProperty("hotkey", &hotkey);
    engine.load(QUrl(QStringLiteral("qrc:/Main.qml")));
    if (engine.rootObjects().isEmpty())
        return 1;
    auto *window = qobject_cast<QQuickWindow *>(engine.rootObjects().first());
    if (!window)
        return 1;
    auto showWindow = [window] {
        window->show();
        window->raise();
        window->requestActivate();
    };
    QQmlComponent hotkeyComponent(&engine, QUrl(QStringLiteral("qrc:/Hotkey.qml")));
    auto *hotkeyWindow = qobject_cast<QQuickWindow *>(hotkeyComponent.create());
    if (!hotkeyWindow) {
        qWarning() << "Cannot create shortcut window:" << hotkeyComponent.errors();
        return 1;
    }
    QMenu trayMenu;
    QAction *toggleAction = trayMenu.addAction(QObject::tr("Start dictation"));
    QMenu *historyMenu = trayMenu.addMenu(QObject::tr("History"));
    QMenu *hotkeysMenu = trayMenu.addMenu(QObject::tr("Hotkeys"));
    QAction *hotkeyAction = hotkeysMenu->addAction(QObject::tr("Set dictation hotkey…"));
    QAction *notificationsAction = trayMenu.addAction(QObject::tr("Notifications"));
    notificationsAction->setCheckable(true);
    trayMenu.addSeparator();
    QAction *aboutAction = trayMenu.addAction(QObject::tr("About Dikta"));
    QAction *quitAction = trayMenu.addAction(QObject::tr("Quit"));
    QSystemTrayIcon tray;
    tray.setContextMenu(&trayMenu);
    QObject::connect(toggleAction, &QAction::triggered, &backend, &Backend::toggle);
    QObject::connect(aboutAction, &QAction::triggered, &app, showWindow);
    QObject::connect(notificationsAction, &QAction::triggered, &backend, &Backend::setNotificationsEnabled);
    auto updateTray = [&] {
        const QString icon = backend.recording() ? QStringLiteral("recording")
            : (backend.busy() ? QStringLiteral("processing") : QStringLiteral("mic"));
        if (icon == QStringLiteral("mic")) {
            QFile source(QStringLiteral(":/mic.svg"));
            const QByteArray sourceSvg = source.open(QIODevice::ReadOnly) ? source.readAll() : QByteArray();
            QByteArray svg = sourceSvg;
            svg.replace("#eeeeee", theme.foreground().toUtf8());
            QSvgRenderer renderer(svg);
            QPixmap pixmap(48, 48);
            pixmap.fill(Qt::transparent);
            QPainter painter(&pixmap);
            renderer.render(&painter);
            painter.end();
            tray.setIcon(QIcon(pixmap));
        } else {
            tray.setIcon(QIcon(QStringLiteral(":/") + icon + QStringLiteral(".svg")));
        }
        tray.setToolTip(QStringLiteral("Dikta — ") + backend.status());
        notificationsAction->setChecked(backend.notificationsEnabled());
        toggleAction->setText(backend.recording() ? QObject::tr("Stop dictation") : QObject::tr("Start dictation"));
        toggleAction->setEnabled(!backend.busy());
        historyMenu->clear();
        const QStringList history = backend.history();
        if (history.isEmpty()) {
            historyMenu->addAction(QObject::tr("No recent dictations"))->setEnabled(false);
        } else {
            for (int index = 0; index < history.size(); ++index) {
                QString preview = history.at(index).simplified();
                if (preview.size() > 80)
                    preview = preview.left(77) + QStringLiteral("…");
                QAction *action = historyMenu->addAction(preview);
                QObject::connect(action, &QAction::triggered, &backend, [&, index] { backend.copyHistory(index); });
            }
        }
    };
    QObject::connect(&backend, &Backend::changed, &app, updateTray);
    QObject::connect(&theme, &Theme::changed, &app, updateTray);
    auto showHotkeyWindow = [hotkeyWindow] {
        hotkeyWindow->show();
        hotkeyWindow->raise();
        hotkeyWindow->requestActivate();
    };
    QObject::connect(hotkeyAction, &QAction::triggered, &app, showHotkeyWindow);
    QObject::connect(quitAction, &QAction::triggered, &app, &QCoreApplication::quit);
    QObject::connect(&tray, &QSystemTrayIcon::activated, &app,
                     [&](QSystemTrayIcon::ActivationReason reason) {
        if (reason == QSystemTrayIcon::Trigger)
            showWindow();
    });
    updateTray();
    tray.show();
    const QString panelPath = directory + QStringLiteral("/panel.json");
    auto updatePanel = [&] {
        QJsonArray history;
        const QStringList entries = backend.history();
        for (int index = 0; index < entries.size() && index < 5; ++index) {
            QString preview = entries.at(index).simplified();
            if (preview.size() > 80)
                preview = preview.left(77) + QStringLiteral("…");
            history.append(preview);
        }
        const QJsonObject state {
            {QStringLiteral("status"), backend.status()},
            {QStringLiteral("recording"), backend.recording()},
            {QStringLiteral("busy"), backend.busy()},
            {QStringLiteral("notifications"), backend.notificationsEnabled()},
            {QStringLiteral("hotkey"), hotkey.current()},
            {QStringLiteral("history"), history}
        };
        const QByteArray json = QJsonDocument(state).toJson(QJsonDocument::Compact);
        QSaveFile file(panelPath);
        if (!file.open(QIODevice::WriteOnly)
            || !file.setPermissions(QFileDevice::ReadOwner | QFileDevice::WriteOwner)
            || file.write(json) != json.size() || !file.commit()) {
            QFile::remove(panelPath);
            qWarning("Cannot publish Dikta panel state.");
        }
    };
    QObject::connect(&backend, &Backend::changed, &app, updatePanel);
    QObject::connect(&hotkey, &Hotkey::changed, &app, updatePanel);
    updatePanel();
    QObject::connect(&server, &QLocalServer::newConnection, &app, [&] {
        while (QLocalSocket *client = server.nextPendingConnection()) {
            QObject::connect(client, &QLocalSocket::disconnected, client, &QObject::deleteLater);
            QObject::connect(client, &QLocalSocket::readyRead, client, [&, client] {
                if (!client->canReadLine()) {
                    if (client->bytesAvailable() > 64)
                        client->disconnectFromServer();
                    return;
                }
                const QByteArray request = client->readLine(65).chopped(1);
                if (request == "toggle")
                    backend.toggle();
                else if (request == "show")
                    showWindow();
                else if (request == "hotkey")
                    showHotkeyWindow();
                else if (request == "notifications")
                    backend.setNotificationsEnabled(!backend.notificationsEnabled());
                else if (request == "quit")
                    QObject::connect(client, &QLocalSocket::disconnected, &app, &QCoreApplication::quit);
                else if (request.size() == 6 && validPanelAction(request))
                    backend.copyHistory(request.at(5) - '0');
                else if (request != "ping") {
                    client->disconnectFromServer();
                    return;
                }
                client->write("ok\n");
                client->disconnectFromServer();
            });
        }
    });
    if (toggle)
        QTimer::singleShot(0, &backend, &Backend::toggle);
    else if (!background)
        showWindow();
    const int result = app.exec();
    QFile::remove(panelPath);
    return result;
}
