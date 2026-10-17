// Runs the Google Apps Script that Hammer gives you (DeliveryScript.template in
// Deliveries.swift) in Node, with stand-ins for Gmail, Session and ContentService.
//   node script_test.js path/to/extracted-script.js
// Tests/Deliveries/run.sh extracts the script and runs this.
'use strict';
const fs = require('fs');
const vm = require('vm');

let failures = 0;
function check(ok, what) {
  console.log(`  ${ok ? 'ok  ' : 'FAIL'} ${what}`);
  if (!ok) failures += 1;
}

const source = fs.readFileSync(process.argv[2], 'utf8');
const KEY = 'a'.repeat(64);
const DAY = 24 * 60 * 60 * 1000;
const now = Date.now();

function message(id, subject, ageDays, extra = {}) {
  return {
    getId: () => id,
    getDate: () => new Date(now - ageDays * DAY),
    isInTrash: () => !!extra.trash,
    getHeader: (name) => (name === 'Message-ID' ? (extra.messageID === undefined ? `<${id}@mail>` : extra.messageID) : ''),
    getFrom: () => extra.from || '"eBay" <ebay@ebay.com>',
    getSubject: () => subject,
  };
}

function sandbox(threads, options = {}) {
  const calls = { search: [], logged: [] };
  const context = {
    GmailApp: {
      search(query, start, max) {
        calls.search.push({ query, start, max });
        if (options.throws) throw new Error('Service invoked too many times for one day: gmail.');
        return threads.map((messages) => ({ getMessages: () => messages }));
      },
    },
    Session: { getEffectiveUser: () => ({ getEmail: () => 'you@gmail.com' }) },
    ContentService: {
      MimeType: { JSON: 'application/json' },
      createTextOutput(text) {
        return { text, mime: null, setMimeType(m) { this.mime = m; return this; }, getContent() { return this.text; } };
      },
    },
    Logger: { log: (text) => calls.logged.push(text) },
    Date, JSON, String,
  };
  vm.createContext(context);
  vm.runInContext(source, context, { filename: 'Code.gs' });
  return { context, calls };
}

function get(context, parameter) {
  const out = context.doGet(parameter === undefined ? undefined : { parameter });
  return { body: JSON.parse(out.getContent()), mime: out.mime };
}

console.log('[the script]');
check(!source.includes('__HAMMER_KEY__'), 'the key is filled in');
check(/const HAMMER_KEY = '[0-9a-f]{64}';/.test(source), 'with a 64-character key');

const threads = [
  [message('m1', 'Your package was delivered: Apple iPhone 15 Pro Max', 0.1),
   message('m0', 'Shipped: Apple iPhone 15 Pro Max', 3)],                 // older than 2 days: left out
  [message('m2', 'Delivered: "Cable"', 0.5, { from: 'Amazon.com <a@amazon.com>', messageID: '' })],
  [message('m3', 'Your package was delivered', 0.2, { trash: true })],  // in the trash: left out
];

console.log('[the key]');
let { context, calls } = sandbox(threads);
check(get(context, undefined).body.error === 'key', 'no request details: refused');
check(get(context, {}).body.error === 'key', 'no key: refused');
check(get(context, { key: 'b'.repeat(64) }).body.error === 'key', 'wrong key: refused');
check(calls.search.length === 0, 'and Gmail is never touched without the key');

console.log('[answer]');
const { body, mime } = get(context, { key: KEY, v: '1' });
check(body.ok === true && body.version === 1 && body.account === 'you@gmail.com', 'ok, with the account');
check(mime === 'application/json', 'sent as JSON');
check(JSON.stringify(body.emails.map((e) => e.id)) === '["m1","m2"]', `recent, not in the trash: ${body.emails.map((e) => e.id)}`);
const first = body.emails[0];
check(first.from === '"eBay" <ebay@ebay.com>' && first.subject.startsWith('Your package was delivered')
      && first.messageID === '<m1@mail>' && !isNaN(Date.parse(first.date)), 'sender, subject, Message-ID and date');
check(body.emails[1].messageID === '', 'a missing Message-ID is an empty string');
check(Object.keys(first).sort().join(',') === 'date,from,id,messageID,subject', 'nothing else about the email is sent');
const search = calls.search[0];
check(search.query.startsWith('in:inbox newer_than:2d subject:(') && search.query.includes('"dropped off"'),
      'searches the inbox, last 2 days, delivery words');
check(search.start === 0 && search.max === 20, 'at most 20 conversations');

console.log('[Gmail error]');
({ context } = sandbox(threads, { throws: true }));
const failed = get(context, { key: KEY }).body;
check(failed.ok === false && failed.error === 'gmail' && failed.message.includes('too many times'), 'reported, not thrown');

console.log('[empty inbox]');
({ context } = sandbox([]));
check(JSON.stringify(get(context, { key: KEY }).body.emails) === '[]', 'an empty list');

console.log('[test() in the editor]');
({ context, calls } = sandbox(threads));
context.test();
check(calls.logged.length === 1 && calls.logged[0].includes('m1'), 'logs what Hammer would get');

console.log(failures === 0 ? 'passed' : `${failures} FAILED`);
process.exit(failures === 0 ? 0 : 1);
