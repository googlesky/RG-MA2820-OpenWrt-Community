// Read-only CLED edge sampler. Never inspect /proc/gpio/N: that changes pinmux.
// Buffer output until sampling finishes so SSH logging does not drive activity.
'use strict';
import { open } from 'fs';
let duration = int(ARGV[0] || '5000');
if (duration < 100 || duration > 30000) die('duration must be 100..30000 ms\n');
function ms() { let t = clock(true); return t[0] * 1000 + t[1] / 1000000; }
let begin = ms(), edges = [], last = null;
while (ms() - begin < duration) {
	let file = open('/proc/bcm_cled/swled_enable', 'r');
	if (!file) die('CLED read failed\n');
	let value = trim(file.read('all'));
	file.close();
	if (value != last) { push(edges, [ms() - begin, value]); last = value; }
	sleep(2);
}
print(sprintf('%J\n', { duration_ms: ms() - begin, edges: edges }));
