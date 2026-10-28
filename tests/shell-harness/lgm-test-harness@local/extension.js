// Test-only helper loaded ONLY inside the throwaway headless shell started by
// run-headless.sh. Opens the LG Monitor Switch menu, logs slider values and
// writes screenshots to $LGM_HARNESS_OUT.
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import Shell from 'gi://Shell';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';

const UUID = 'lg-monitor-switch@entangledquantum.github.io';
const OUT = GLib.getenv('LGM_HARNESS_OUT') || '/tmp';

function later(seconds, fn) {
    return GLib.timeout_add(GLib.PRIORITY_DEFAULT, seconds * 1000, () => {
        try {
            fn();
        } catch (e) {
            console.log(`HARNESS error ${e}`);
        }
        return GLib.SOURCE_REMOVE;
    });
}

function shot(name) {
    const file = Gio.File.new_for_path(`${OUT}/${name}`);
    const stream = file.replace(null, false, Gio.FileCreateFlags.NONE, null);
    const shooter = new Shell.Screenshot();
    shooter.screenshot(false, stream, (o, res) => {
        try {
            shooter.screenshot_finish(res);
            stream.close(null);
            console.log(`HARNESS screenshot ${name}`);
        } catch (e) {
            console.log(`HARNESS screenshot error ${e}`);
        }
    });
}

export default class Harness extends Extension {
    enable() {
        Main.layoutManager.connect('startup-complete', () => {});
        later(4, () => {
            if (Main.overview.visible)
                Main.overview.hide();
        });
        later(7, () => {
            const ext = Main.extensionManager.lookup(UUID);
            console.log(`HARNESS extension state=${ext?.state} error=${ext?.error ?? ''}`);
            const ind = Main.panel.statusArea[UUID];
            console.log(`HARNESS indicator=${!!ind}`);
            ind?.menu.open(false);
        });
        later(11, () => {
            const ind = Main.panel.statusArea[UUID];
            if (ind) {
                console.log(`HARNESS brightness=${ind._brightness.value} contrast=${ind._contrast.value} ` +
                    `switch="${ind._switchItem.label.text}" status="${ind._status.visible ? ind._status.label.text : ''}"`);
            }
            shot('menu.png');
        });
        if (GLib.getenv('LGM_WRITE_TEST') === '1') {
            // Simulate a slider drag (70 -> 75 -> 80 %): the debounce must send
            // only the final value. Restores the original value afterwards.
            let original = null;
            later(12, () => {
                const b = Main.panel.statusArea[UUID]._brightness;
                original = b.value;
                for (const v of [0.70, 0.75, 0.80])
                    b.slider.value = v;
                console.log(`HARNESS drag brightness ${original} -> 80`);
            });
            later(15, () => {
                const proc = Gio.Subprocess.new([`${GLib.get_home_dir()}/.local/bin/lg-monitor`, 'get', '--json'],
                    Gio.SubprocessFlags.STDOUT_PIPE);
                proc.communicate_utf8_async(null, null, (p, res) => {
                    const [, out] = p.communicate_utf8_finish(res);
                    console.log(`HARNESS after drag: ${out.trim()}`);
                    Main.panel.statusArea[UUID]._brightness.slider.value = original / 100;
                    console.log(`HARNESS restoring brightness ${original}`);
                });
            });
        }
        later(19, () => Main.panel.statusArea[UUID]?.menu.close(false));
        later(20, () => {
            // Make the settings window tall enough to show every section.
            for (const actor of global.get_window_actors()) {
                const win = actor.meta_window;
                if (win.get_title()?.includes('LG Monitor')) {
                    if (win.maximized_horizontally || win.maximized_vertically)
                        win.unmaximize(3);
                    const area = Main.layoutManager.getWorkAreaForMonitor(0);
                    win.move_resize_frame(true, area.x + 40, area.y + 10, 680, area.height - 20);
                    console.log(`HARNESS settings window resized`);
                }
            }
        });
        later(24, () => shot('settings.png'));
    }

    disable() {}
}
