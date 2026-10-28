// SPDX-License-Identifier: MIT
// LG Monitor Switch - top bar menu with Brightness / Contrast sliders and an
// input "Switch" button. All monitor access goes through the `lg-monitor`
// command line tool (ddcutil + i2ctransfer), installed in ~/.local/bin.

import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import GObject from 'gi://GObject';
import St from 'gi://St';

import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as PanelMenu from 'resource:///org/gnome/shell/ui/panelMenu.js';
import * as PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js';
import {Slider} from 'resource:///org/gnome/shell/ui/slider.js';

const DEBOUNCE_MS = 300;
const SETTINGS_DESKTOP_ID = 'io.github.entangledquantum.LgMonitorSwitch.desktop';

function findProgram(name) {
    const local = GLib.build_filenamev([GLib.get_home_dir(), '.local', 'bin', name]);
    if (GLib.file_test(local, GLib.FileTest.IS_EXECUTABLE))
        return local;
    return GLib.find_program_in_path(name);
}

function runCli(args, cancellable) {
    return new Promise((resolve, reject) => {
        const cli = findProgram('lg-monitor');
        if (!cli) {
            reject(new Error('lg-monitor not found - run install.sh'));
            return;
        }
        let proc;
        try {
            proc = Gio.Subprocess.new([cli, ...args],
                Gio.SubprocessFlags.STDOUT_PIPE | Gio.SubprocessFlags.STDERR_PIPE);
        } catch (e) {
            reject(e);
            return;
        }
        proc.communicate_utf8_async(null, cancellable, (p, res) => {
            try {
                const [, stdout, stderr] = p.communicate_utf8_finish(res);
                resolve({ok: p.get_successful(), stdout: stdout ?? '', stderr: (stderr ?? '').trim()});
            } catch (e) {
                reject(e);
            }
        });
    });
}

// One slider row: icon, slider, value label. Writes are debounced and never
// overlap: while a write runs, newer values are queued and sent afterwards.
const LevelItem = GObject.registerClass(
class LevelItem extends PopupMenu.PopupBaseMenuItem {
    _init(params) {
        super._init({activate: false, style_class: 'lg-monitor-row'});
        this._command = params.command;
        this._onError = params.onError;
        this._cancellable = params.cancellable;
        this._timeoutId = 0;
        this._busy = false;
        this._pending = null;
        this._lastSent = null;

        this.add_child(new St.Icon({gicon: params.gicon, style_class: 'popup-menu-icon'}));
        this.slider = new Slider(0);
        this.slider.accessible_name = params.label;
        this._changedId = this.slider.connect('notify::value', () => this._onSliderChanged());
        this.add_child(this.slider);
        this._valueLabel = new St.Label({
            text: '–',
            style_class: 'lg-monitor-value',
            y_align: Clutter.ActorAlign.CENTER,
        });
        this.add_child(this._valueLabel);
        this.connect('key-press-event', (actor, event) => this.slider.vfunc_key_press_event(event));
    }

    get value() {
        return Math.round(this.slider.value * 100);
    }

    setValue(value) {
        if (this._busy || this._timeoutId || this._pending !== null)
            return; // user is changing it right now; keep their value
        this.slider.block_signal_handler(this._changedId);
        this.slider.value = value / 100;
        this.slider.unblock_signal_handler(this._changedId);
        this._valueLabel.text = `${value}%`;
        this._lastSent = value;
    }

    _onSliderChanged() {
        this._valueLabel.text = `${this.value}%`;
        if (this._timeoutId)
            GLib.source_remove(this._timeoutId);
        this._timeoutId = GLib.timeout_add(GLib.PRIORITY_DEFAULT, DEBOUNCE_MS, () => {
            this._timeoutId = 0;
            this._pending = this.value;
            this._flush();
            return GLib.SOURCE_REMOVE;
        });
    }

    async _flush() {
        if (this._busy || this._pending === null)
            return;
        const value = this._pending;
        this._pending = null;
        if (value === this._lastSent)
            return;
        this._busy = true;
        try {
            const res = await runCli([this._command, String(value)], this._cancellable);
            if (res.ok)
                this._lastSent = value;
            else
                this._onError(res.stderr || `${this._command} failed`);
        } catch (e) {
            if (!e.matches?.(Gio.IOErrorEnum, Gio.IOErrorEnum.CANCELLED))
                this._onError(e.message);
        } finally {
            this._busy = false;
        }
        if (this._pending !== null)
            this._flush();
    }

    destroy() {
        if (this._timeoutId) {
            GLib.source_remove(this._timeoutId);
            this._timeoutId = 0;
        }
        super.destroy();
    }
});

const Indicator = GObject.registerClass(
class Indicator extends PanelMenu.Button {
    _init(extension) {
        super._init(0.0, 'LG Monitor Switch');
        this._extension = extension;
        this._cancellable = new Gio.Cancellable();
        const iconPath = name => Gio.FileIcon.new(extension.dir.get_child('icons').get_child(name));

        this.add_child(new St.Icon({
            gicon: iconPath('lg-monitor-switch-symbolic.svg'),
            style_class: 'system-status-icon',
        }));

        this.menu.box.add_style_class_name('lg-monitor-menu');

        const header = new PopupMenu.PopupMenuItem('LG Monitor', {reactive: false});
        header.label.style = 'font-weight: bold;';
        this.menu.addMenuItem(header);

        const onError = msg => this._setStatus(msg);
        this._brightness = new LevelItem({
            label: 'Brightness',
            command: 'set-brightness',
            gicon: Gio.ThemedIcon.new('display-brightness-symbolic'),
            cancellable: this._cancellable,
            onError,
        });
        this._contrast = new LevelItem({
            label: 'Contrast',
            command: 'set-contrast',
            gicon: iconPath('contrast-symbolic.svg'),
            cancellable: this._cancellable,
            onError,
        });
        this.menu.addMenuItem(this._brightness);
        this.menu.addMenuItem(this._contrast);

        this._status = new PopupMenu.PopupMenuItem('', {reactive: false});
        this._status.label.add_style_class_name('lg-monitor-status');
        this._status.visible = false;
        this.menu.addMenuItem(this._status);

        this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());

        this._switchItem = new PopupMenu.PopupImageMenuItem('Switch to Windows',
            iconPath('lg-monitor-switch-symbolic.svg'));
        this._switchItem.connect('activate', () => this._switch());
        this.menu.addMenuItem(this._switchItem);

        const settingsItem = new PopupMenu.PopupImageMenuItem('Settings…', 'emblem-system-symbolic');
        settingsItem.connect('activate', () => this._openSettings());
        this.menu.addMenuItem(settingsItem);

        this.menu.connect('open-state-changed', (menu, open) => {
            if (open)
                this._refresh();
        });
    }

    _setStatus(text) {
        this._status.label.text = text ?? '';
        this._status.visible = !!text;
    }

    async _refresh() {
        this._setStatus('Reading monitor…');
        try {
            const res = await runCli(['get', '--json'], this._cancellable);
            let info = {};
            try {
                info = JSON.parse(res.stdout);
            } catch {
                info = {error: res.stderr || 'unexpected output from lg-monitor'};
            }
            if (info.switch_label)
                this._switchItem.label.text = `Switch to ${info.switch_label}`;
            if (info.error) {
                this._setStatus(info.error);
                return;
            }
            this._brightness.setValue(info.brightness);
            this._contrast.setValue(info.contrast);
            this._setStatus(null);
        } catch (e) {
            if (!e.matches?.(Gio.IOErrorEnum, Gio.IOErrorEnum.CANCELLED))
                this._setStatus(e.message);
        }
    }

    async _switch() {
        try {
            const res = await runCli(['switch'], this._cancellable);
            if (!res.ok)
                Main.notify('LG Monitor Switch', res.stderr || 'Input switch failed');
        } catch (e) {
            if (!e.matches?.(Gio.IOErrorEnum, Gio.IOErrorEnum.CANCELLED))
                Main.notify('LG Monitor Switch', e.message);
        }
    }

    _openSettings() {
        try {
            const app = Gio.DesktopAppInfo.new(SETTINGS_DESKTOP_ID);
            if (app) {
                app.launch([], global.create_app_launch_context(0, -1));
                return;
            }
            const prog = findProgram('lg-monitor-settings');
            if (!prog)
                throw new Error('lg-monitor-settings not found - run install.sh');
            Gio.Subprocess.new([prog], Gio.SubprocessFlags.NONE);
        } catch (e) {
            Main.notify('LG Monitor Switch', e.message);
        }
    }

    destroy() {
        this._cancellable.cancel();
        super.destroy();
    }
});

export default class LgMonitorSwitchExtension extends Extension {
    enable() {
        this._indicator = new Indicator(this);
        Main.panel.addToStatusArea(this.uuid, this._indicator);
    }

    disable() {
        this._indicator?.destroy();
        this._indicator = null;
    }
}
