// Workflow C - Render customer replies from the database result. No prices or availability are computed here.
const ev = $('Claim Event').first().json.ev;
const S = ($('Load Context').first().json || {}).settings || {};
const parsed = $('Parse Intent').first().json || {};
const R = $input.first().json.result || {};
//@@LIB@@
const first = (String(ev.name || '').match(/^[\p{L}]{2,20}/u) || [''])[0];
const T = (body) => ({ message: { type: 'text', text: { body: clip(body, 4000), preview_url: false } }, fallback_text: clip(body, 4000) });
// buttons: [{id,title,cmd}] (max 3). fallback tells the customer which words to type.
function B(body, btns) {
  btns = btns.slice(0, 3);
  const fb = clip(body, 3800) + '\n\nReply with: ' + btns.map(b => '*' + (b.cmd || b.title) + '*').join('  |  ');
  return { message: { type: 'interactive', interactive: { type: 'button', body: { text: clip(body, 1024) },
    action: { buttons: btns.map(b => ({ type: 'reply', reply: { id: b.id, title: clip(b.title, 20) } })) } } }, fallback_text: fb };
}
// list: rows [{id,title,description,cmd}] (max 10)
function LST(body, label, title, rows) {
  rows = rows.slice(0, 10);
  const fb = clip(body, 2500) + '\n\n' + rows.map((r, i) => (i + 1) + '. ' + r.title + (r.description ? ' — ' + r.description : '') + (r.cmd ? '  → reply *' + r.cmd + '*' : '')).join('\n');
  return { message: { type: 'interactive', interactive: { type: 'list', body: { text: clip(body, 1024) },
    action: { button: clip(label, 20), sections: [{ title: clip(title, 24), rows: rows.map(r => ({ id: r.id, title: clip(r.title, 24), description: r.description ? clip(r.description, 72) : undefined })) }] } } }, fallback_text: clip(fb, 4000) };
}
const CAT = { CAKES: 'Cakes', PASTRIES: 'Pastries', COOKIES: 'Cookies', BREAD: 'Bread', CUSTOM_CAKES: 'Custom cakes' };
const MAIN_BTNS = [{ id: 'MENU', title: 'Browse menu', cmd: 'menu' }, { id: 'CART', title: 'My cart', cmd: 'cart' }, { id: 'STATUS', title: 'Order status', cmd: 'status' }];
const CART_BTNS = [{ id: 'CHECKOUT', title: 'Checkout', cmd: 'checkout' }, { id: 'MENU', title: 'Add more', cmd: 'menu' }, { id: 'CLEAR', title: 'Clear cart', cmd: 'clear cart' }];
const cartBlock = (c) => (c && c.lines && c.lines.length ? c.lines.map(lineText).join('\n') + '\n' + totalsText(c) : '');
const pre = (R.cart_expired ? 'Your earlier cart expired, so we are starting fresh. ' : '');
function timeErr(code, lead) {
  switch (code) {
    case 'PAST': return 'That time has already passed.';
    case 'TOO_SOON': return 'We need at least ' + leadText(lead) + ' notice for this order.';
    case 'TOO_FAR': return 'That is too far ahead — please choose a date within the next ' + (S.max_advance_days || 30) + ' days.';
    case 'CLOSED': return 'We are closed at that time. Our hours: ' + hoursText() + '.';
    default: return 'I could not read that time. Try something like “tomorrow 5 PM” or “28 Oct 11:30 AM”.';
  }
}
let msgs = [];
switch (R.code) {
  case 'WELCOME':
    msgs = [B('Hi' + (first ? ' ' + first : '') + '! 👋 Welcome to *' + (S.bakery_name || 'our bakery') + '*.\nOrder cakes, pastries, cookies and bread right here. Tap an option, or just type what you want, e.g. “I want a 1 kg chocolate cake”.', MAIN_BTNS)]; break;
  case 'HELP':
    msgs = [B('Here is what you can say:\n• *menu* / *show the cakes*\n• “add two chocolate pastries”\n• “remove item 2”, “change item 1 to 2 kg”\n• *cart*, *checkout*, *confirm*\n• “status” or “cancel my order”\nOpening hours: ' + hoursText() + '.', MAIN_BTNS)]; break;
  case 'MENU_CATEGORIES':
    msgs = [LST('What would you like to see?', 'Choose category', 'Categories', (R.categories || []).map(c => ({ id: 'MENU:' + c.category, title: CAT[c.category] || c.category, description: c.count + ' item' + (c.count === 1 ? '' : 's'), cmd: (CAT[c.category] || c.category).toLowerCase() })))]; break;
  case 'MENU_ITEMS': {
    const items = R.items || [];
    msgs = items.length ? [LST('*' + (CAT[R.category] || R.category) + '* — tap an item to add it. (Prices shown are “from” prices.)', 'View items', CAT[R.category] || 'Items',
      items.map(i => ({ id: 'ADD:' + i.code + ':1', title: i.name, description: 'from ' + fmt(i.from_price_minor) + (i.description ? ' · ' + i.description : ''), cmd: 'add ' + i.code })))]
      : [B('Nothing is available in that category right now.', MAIN_BTNS)];
    break; }
  case 'CLARIFY_PRODUCT':
    msgs = [LST('Which one did you mean?', 'Choose item', 'Matches', (R.matches || []).map(x => ({ id: 'ADD:' + x.code + ':' + (R.quantity || 1), title: x.name, cmd: 'add ' + x.code })))]; break;
  case 'PRODUCT_NOT_FOUND':
    msgs = [B('I could not find that item. Please pick from our menu, or type a product name such as “chocolate pastry”.', MAIN_BTNS)]; break;
  case 'UNAVAILABLE':
    msgs = [T('Sorry, *' + plain(R.name, 80) + '* is not available' + (R.available !== undefined ? ' in that quantity (only ' + R.available + ' left)' : ' right now') + '.')]; break;
  case 'INVALID_QUANTITY':
    msgs = [T('Please choose a whole number' + (R.name ? ' of *' + plain(R.name, 60) + '*' : '') + ' from 1 to ' + (R.max || 20) + '.')]; break;
  case 'INVALID_OPTION': {
    const ch = (R.choices || []).join(', ');
    msgs = [T(R.field === 'message' ? 'The cake message can be up to ' + (R.max || 40) + ' characters (letters, numbers and simple punctuation).' : 'Sorry, I do not have that ' + R.field + '. Options: ' + ch + '.')]; break; }
  case 'ASK_OPTION': {
    const lead = R.invalid ? 'Sorry, I could not use that. ' : '';
    const ch = R.choices || [];
    if (R.field === 'variant') {
      const rows = ch.map(v => ({ id: 'VAR:' + v.label, title: v.label, description: fmt(v.price_minor), cmd: v.label }));
      msgs = [rows.length <= 3 ? B(lead + 'Which size for *' + plain(R.product, 60) + '*?', rows.map(r => ({ id: r.id, title: r.title + ' ' + r.description, cmd: r.cmd }))) : LST(lead + 'Which size for *' + plain(R.product, 60) + '*?', 'Choose size', 'Sizes', rows)];
    } else if (R.field === 'message') {
      msgs = [B(lead + 'What should we write on the cake? (up to ' + (R.message_max || 40) + ' characters). Or tap Skip for no message.', [{ id: 'SKIP', title: 'Skip', cmd: 'skip' }])];
    } else {
      const rows = ch.map(c => ({ id: 'OPT:' + R.field + ':' + c, title: c, cmd: c }));
      const q = { flavor: 'Which flavor?', egg: 'Egg or eggless?', frosting: 'Which frosting?' }[R.field] || 'Please choose:';
      msgs = [rows.length <= 3 ? B(lead + q, rows) : LST(lead + q, 'Choose', R.field, rows)];
    }
    break; }
  case 'VARIANT_NOT_FOUND':
    msgs = [T('Sorry, *' + plain(R.product, 60) + '* is available in: ' + (R.choices || []).map(v => v.label + ' (' + fmt(v.price_minor) + ')').join(', ') + '.')]; break;
  case 'CART_UPDATED': {
    const c = R.change || {};
    const head = c.type === 'ADDED' ? '✅ Added ' + c.quantity + ' × ' + plain(c.name, 60) + ' (' + plain(c.variant, 20) + ').' : c.type === 'REMOVED' ? '🗑️ Updated your cart (' + plain(c.name, 60) + ').' : '✏️ Updated ' + plain(c.name, 60) + '.';
    msgs = [B(pre + head + '\n\n*Your cart*\n' + cartBlock(R.cart), CART_BTNS)]; break; }
  case 'CART':
    msgs = [B(pre + '*Your cart*\n' + cartBlock(R.cart), CART_BTNS)]; break;
  case 'CART_EMPTY':
    msgs = [B(pre + 'Your cart is empty. What would you like to order?', [{ id: 'MENU', title: 'Browse menu', cmd: 'menu' }])]; break;
  case 'CART_CLEARED': msgs = [B('Your cart is cleared.', [{ id: 'MENU', title: 'Browse menu', cmd: 'menu' }])]; break;
  case 'CART_CANCELLED': msgs = [B('Okay — I have cancelled your unconfirmed cart.', [{ id: 'MENU', title: 'Start again', cmd: 'menu' }])]; break;
  case 'FLOW_CANCELLED': msgs = [B('Okay, nothing changed.', MAIN_BTNS)]; break;
  case 'LINE_NOT_FOUND': msgs = [T('I could not find that item in your cart.\n\n' + cartBlock(R.cart) + '\n\nTell me the item number, e.g. “remove item 2”.')]; break;
  case 'CLARIFY_LINE': msgs = [T('Which one do you mean?\n\n' + cartBlock(R.cart) + '\n\nTell me the item number, e.g. “change item 2 to 2 kg”.')]; break;
  case 'EDIT_WHAT': msgs = [T('What should I change?\n\n' + cartBlock(R.cart) + '\n\nFor example “change item 1 to 2 kg” or “change item 2 to 3”.')]; break;
  case 'EDIT_PROMPT': msgs = [B('No problem. ' + (R.cart ? 'Tell me what to change:\n\n' + cartBlock(R.cart) + '\n\nOr tap Checkout when ready.' : 'Your cart is empty.'), R.cart ? CART_BTNS : MAIN_BTNS)]; break;
  case 'ASK_DETAIL': {
    const f = R.field, e = R.error ? timeErr(R.error, R.lead_minutes) + ' ' : '';
    if (f === 'fulfillment') {
      const bt = (R.methods || []).map(m => m === 'PICKUP' ? { id: 'FUL:PICKUP', title: 'Pickup', cmd: 'pickup' } : { id: 'FUL:DELIVERY', title: 'Delivery', cmd: 'delivery' });
      msgs = [B((R.error ? 'Please tap one of the options. ' : '') + 'Would you like pickup or delivery?' + (S.delivery_fee_minor ? '\nDelivery fee: ' + fmt(S.delivery_fee_minor) + (S.min_delivery_order_minor ? ' (minimum order ' + fmt(S.min_delivery_order_minor) + ')' : '') : ''), bt.length ? bt : [{ id: 'FUL:PICKUP', title: 'Pickup', cmd: 'pickup' }])];
    } else if (f === 'time') msgs = [T(e + 'When would you like it? Tell me the day and time, e.g. “tomorrow 5 PM”.\nWe need at least ' + leadText(R.lead_minutes) + ' notice. Hours: ' + hoursText() + '.')];
    else if (f === 'name') msgs = [T('What name should I put on the order?')];
    else msgs = [T('Please send your full delivery address (house/flat, street, area, city, PIN).')];
    break; }
  case 'DETAIL_ERROR': {
    const er = R.error || {};
    msgs = [T(er.field === 'time' ? timeErr(er.code, R.lead_minutes) + ' When would you like it?' : er.field === 'method' ? 'Sorry, that option is not available right now.' : er.field === 'name' ? 'Please send just your name (letters only, up to 60 characters).' : 'Please send a complete address (10 to 300 characters).')]; break; }
  case 'DETAILS_SAVED': msgs = [B(pre + 'Got it ✅' + (R.cart && R.cart.fulfillment_method ? '\n' + whenText(R.cart) : '') + (R.cart && R.cart.item_count ? '' : '\nWhat would you like to order?'), R.cart && R.cart.item_count ? CART_BTNS : [{ id: 'MENU', title: 'Browse menu', cmd: 'menu' }])]; break;
  case 'MIN_DELIVERY': msgs = [B('Delivery needs a minimum order of ' + fmt(R.min_minor) + '. Add more items, or choose pickup.', [{ id: 'FUL:PICKUP', title: 'Switch to pickup', cmd: 'pickup' }, { id: 'MENU', title: 'Add more', cmd: 'menu' }])]; break;
  case 'REVIEW': {
    const c = R.cart;
    const body = (R.stale ? 'Your order changed since you last looked — please review the latest version.\n\n' : '') + '*Please review your order*\n' + cartBlock(c) + '\n\n' + whenText(c) + '\nName: ' + plain(c.contact_name, 60) + (c.fulfillment_method === 'DELIVERY' ? '\nAddress: ' + plain(c.delivery_address, 200) : '') + '\n\n' + (S.payment_instructions || '') + '\n\nTap Confirm to place this order.';
    msgs = [B(body, [{ id: 'CONFIRM:' + c.version, title: 'Confirm order', cmd: 'confirm' }, { id: 'EDIT', title: 'Edit order', cmd: 'edit' }])]; break; }
  case 'ORDER_CONFIRMED': msgs = []; break;              // sent from the outbox after the transaction committed
  case 'ORDER_CANCELLED': msgs = []; break;              // sent from the outbox
  case 'ALREADY_CONFIRMED': msgs = [T('Your order *' + plain(R.order_ref, 40) + '* is already confirmed. Say “status” to check on it.')]; break;
  case 'NOTHING_TO_CONFIRM': msgs = [B('There is nothing to confirm yet. Add something from the menu first.', [{ id: 'MENU', title: 'Browse menu', cmd: 'menu' }])]; break;
  case 'ORDER_STATUS': msgs = [T((R.orders || []).map(o => '*' + o.order_ref + '* — ' + (STATUS_LABEL[o.status] || o.status) + ' (' + (PAY_LABEL[o.payment_status] || o.payment_status) + ')\n' + (o.fulfillment_method === 'DELIVERY' ? 'Delivery' : 'Pickup') + ': ' + o.requested_local + ' · ' + fmt(o.total_minor)).join('\n\n'))]; break;
  case 'ORDER_NOT_FOUND': msgs = [T('I could not find that order on this number.')]; break;
  case 'CANCEL_ORDER_CONFIRM': msgs = [B('Do you want to cancel order *' + plain(R.order_ref, 40) + '*?', [{ id: 'CXLYES:' + R.order_ref, title: 'Yes, cancel it', cmd: 'yes' }, { id: 'NOCXL', title: 'Keep my order', cmd: 'no' }])]; break;
  case 'CANCEL_NOT_ALLOWED': msgs = [T(R.reason === 'FINAL' ? 'Order *' + plain(R.order_ref, 40) + '* is already ' + (STATUS_LABEL[R.status] || R.status).toLowerCase() + '.' : R.reason === 'IN_PROGRESS' ? 'We have already started on order *' + plain(R.order_ref, 40) + '*, so it can no longer be cancelled here. Please contact the bakery' + ((S.bakery_contact || {}).phone ? ' on ' + S.bakery_contact.phone : '') + '.' : 'It is too late to cancel order *' + plain(R.order_ref, 40) + '* here. Please contact the bakery' + ((S.bakery_contact || {}).phone ? ' on ' + S.bakery_contact.phone : '') + '.')]; break;
  case 'RATE_LIMITED': msgs = [T('You are sending messages very quickly. Please wait a minute and try again.')]; break;
  case 'SILENT': msgs = []; break;
  default: msgs = [B('Sorry, I did not catch that. You can type things like “menu”, “add two chocolate pastries” or “cart”.', MAIN_BTNS)];
}
if (parsed.unsupported && R.code !== 'SILENT') msgs = [T('Sorry, I can only read text messages and button taps. Please type what you would like.')];
return [{ json: { event_id: ev.event_id, messages: msgs.slice(0, 5) } }];
