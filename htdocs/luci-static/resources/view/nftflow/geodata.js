'use strict';
'require view';
'require rpc';
'require fs';
'require nftflow.ui as nftflowUi';

var callFileInfo = rpc.declare({
    object: 'luci.nftflow',
    method: 'geodata_info',
    params: [ 'kind' ],
    expect: { '': {} },
    reject: true
});

var CACHE_NAME = 'nftflow-geodata';
var PAGE_SIZE = 100;

function check(value) {
    return nftflowUi.requireOk(value, _('Unable to read GeoData file information.'));
}

function cacheOperation(key, value) {
    if (typeof indexedDB === 'undefined')
        return Promise.resolve(null);

    return new Promise(function(resolve) {
        var completed = false;
        function done(value) {
            if (!completed) { completed = true; resolve(value); }
        }
        var open;
        try { open = indexedDB.open(CACHE_NAME, 1); }
        catch (error) { done(null); return; }

        open.onupgradeneeded = function() {
            if (!open.result.objectStoreNames.contains('files'))
                open.result.createObjectStore('files');
        };
        open.onerror = function() { done(null); };
        open.onblocked = function() { done(null); };
        open.onsuccess = function() {
            var db = open.result, transaction, request;
            try {
                transaction = db.transaction('files', value == null ? 'readonly' : 'readwrite');
                request = value == null
                    ? transaction.objectStore('files').get(key)
                    : transaction.objectStore('files').put(value, key);
                request.onsuccess = function() { done(value == null ? request.result : true); };
                request.onerror = function() { done(null); };
                transaction.oncomplete = function() { db.close(); };
                transaction.onerror = function() { db.close(); done(null); };
                transaction.onabort = function() { db.close(); done(null); };
            } catch (error) { db.close(); done(null); }
        };
    });
}

function cacheMatches(entry, info) {
    return entry && entry.version === 1 && entry.kind === info.kind &&
        entry.source === info.source && entry.size === info.size &&
        entry.mtime === info.mtime && entry.ctime === info.ctime &&
        entry.blob instanceof Blob && entry.blob.size === info.size;
}

function actionButton(label, emphasized) {
    return E('button', {
        'type': 'button',
        'class': 'btn cbi-button cbi-button-' + (emphasized ? 'action' : 'neutral')
    }, label);
}

function dropdown(items) {
    return E('select', { 'class': 'cbi-input-select' },
        items.map(function(item) { return E('option', { value: item[0] }, item[1]); }));
}

function inlineField(label, node, style) {
    return E('label', { 'style': 'display:inline-flex;align-items:center;gap:.5rem;' + (style || '') },
        [ E('span', {}, label), node ]);
}

function resultTable(entries) {
    return E('div', { 'style': 'overflow-x:auto;' }, E('table', {
        'class': 'table'
    }, [
        E('thead', {}, E('tr', {}, [
            E('th', {}, _('Type')),
            E('th', {}, _('Value')),
            E('th', {}, _('Attributes'))
        ])),
        E('tbody', {}, (entries && entries.length ? entries.map(function(e) {
            return E('tr', {}, [
                E('td', {}, E('code', {}, e.type)),
                E('td', { 'style': 'overflow-wrap:anywhere;' }, E('code', {}, e.value)),
                E('td', { 'style': 'overflow-wrap:anywhere;' }, (e.attributes || []).join(', ') || '\u2014')
            ]);
        }) : [ E('tr', {}, E('td', { 'colspan': '3' }, _('No matching entries.'))) ]))
    ]));
}

return view.extend({
    handleSave: null,
    handleSaveApply: null,
    handleReset: null,

    render: function() {
        document.title = _('NftFlow | GeoData');

        var dataset = dropdown([ [ 'geosite', 'GeoSite' ], [ 'geoip', 'GeoIP' ] ]);
        var searchMode = dropdown([
            [ 'match', _('Match rules') ], [ 'text', _('Search text') ]
        ]);
        var query = E('input', {
            'type': 'search', 'class': 'cbi-input-text',
            'placeholder': 'www.youtube.com', 'spellcheck': 'false',
            'autocomplete': 'off', 'style': 'flex:1 1 auto;min-width:8rem;'
        });
        var regex = E('input', { 'type': 'checkbox' });
        var sensitive = E('input', { 'type': 'checkbox' });
        var searchButton = actionButton(_('Search'), true);
        var cancelButton = actionButton(_('Cancel'), false);
        var reloadButton = actionButton(_('Reload file'), false);
        var categoryFilter = E('input', {
            'type': 'search', 'class': 'cbi-input-text',
            'placeholder': _('Filter categories'), 'style': 'width:100%;box-sizing:border-box;'
        });
        var categoryList = E('div', { 'style': 'max-height:34rem;overflow-y:auto;' });
        var entryFilter = E('input', {
            'type': 'search', 'class': 'cbi-input-text', 'placeholder': _('Filter entries'),
            'style': 'min-width:0;flex:1 1 12rem;'
        });
        var entryType = dropdown([ [ 'all', _('All types') ] ]);
        var previous = actionButton(_('Previous'), false);
        var next = actionButton(_('Next'), false);
        var pageInfo = E('span', {}, '');
        var title = E('h3', {}, _('Rules'));
        var output = E('div', {}, _('Select a category to view its rules.'));
        var state = E('div', { 'aria-live': 'polite' });
        var fileInfo = E('span', { 'class': 'cbi-section-descr', 'style': 'flex:1 1 16rem;min-width:0;overflow-wrap:anywhere;' });
        // Use built-in LuCI section, table, input and button styles.
        var browseControls = E('div', {}, [
            E('div', { 'style': 'display:flex;align-items:center;flex-wrap:wrap;gap:.5rem;margin:.75rem 0;' }, [
                entryFilter, entryType, previous, pageInfo, next
            ])
        ]);

        var sourceBar = E('div', { 'class': 'cbi-section' }, [
            E('h3', {}, _('Data Source')),
            E('div', { 'class': 'cbi-section-node' }, [
                E('div', { 'style': 'display:flex;align-items:center;flex-wrap:wrap;gap:.75rem;' }, [
                    inlineField(_('Dataset'), dataset),
                    fileInfo,
                    reloadButton
                ])
            ])
        ]);

        var searchBar = E('div', { 'class': 'cbi-section' }, [
            E('h3', {}, _('Search')),
            E('div', { 'class': 'cbi-section-node' }, [
                E('div', { 'style': 'display:flex;align-items:center;flex-wrap:wrap;gap:.75rem;' }, [
                    inlineField(_('Mode'), searchMode),
                    inlineField(_('Query'), query, 'flex:1 1 16rem;min-width:0;'),
                    E('label', {}, [ regex, ' ', _('Regex') ]),
                    E('label', {}, [ sensitive, ' ', _('Case sensitive') ]),
                    searchButton,
                    cancelButton
                ])
            ])
        ]);

        var layout = E('div', { 'style': 'display:flex;flex-wrap:wrap;gap:1rem;align-items:flex-start;' }, [
            E('div', { 'class': 'cbi-section', 'style': 'flex:1 1 15rem;min-width:0;' }, [
                E('h3', {}, _('Categories')),
                E('div', { 'class': 'cbi-section-node' }, [
                    categoryFilter,
                    categoryList
                ])
            ]),
            E('div', { 'class': 'cbi-section', 'style': 'flex:3 1 30rem;min-width:0;' }, [
                title,
                E('div', { 'class': 'cbi-section-node' }, [
                    browseControls,
                    output
                ])
            ])
        ]);

        var root = E('div', { 'class': 'cbi-map' }, [
            E('h2', {}, _('GeoData Explorer')),
            E('div', { 'class': 'cbi-map-descr' },
                _('GeoSite / GeoIP rules are searched locally in your browser. The router only transfers the DAT file.')),
            sourceBar,
            searchBar,
            state,
            layout
        ]);

        var worker;
        var ready = false, categories = [], selected = null;
        var currentPage = 0, pageTotal = 0, displayedCategories = 160;
        var pending = Object.create(null), serial = 0, revision = 0;

        function setStatus(kind, message) {
            nftflowUi.setState(state, kind, message);
        }

        function send(action, payload, transfers, progress) {
            if (!worker) return Promise.reject(new Error(_('Web Workers are unavailable.')));
            var id = ++serial;
            return new Promise(function(resolve, reject) {
                pending[id] = { resolve: resolve, reject: reject, progress: progress };
                try {
                    worker.postMessage(Object.assign({ action: action, id: id }, payload || {}), transfers || []);
                } catch (error) {
                    delete pending[id];
                    reject(error);
                }
            });
        }

        function invalidate() {
            revision++;
            if (worker) worker.postMessage({ action: 'cancel' });
            Object.keys(pending).forEach(function(key) {
                pending[key].reject(new Error('cancelled'));
                delete pending[key];
            });
            cancelButton.style.display = 'none';
            searchButton.disabled = false;
        }

        function errorMessage(error) {
            setStatus('error', nftflowUi.errorMessage(error));
        }

        function updateModes() {
            regex.disabled = searchMode.value !== 'text';
            sensitive.disabled = searchMode.value !== 'text';
            if (regex.disabled) regex.checked = false;
            if (sensitive.disabled) sensitive.checked = false;
        }

        function typeOptions(kind) {
            var types = kind === 'geoip' ? [ 'cidr' ] :
                [ 'domain', 'full', 'keyword', 'regexp' ];
            entryType.replaceChildren.apply(entryType,
                [ E('option', { value: 'all' }, _('All types')) ].concat(types.map(function(type) {
                    return E('option', { value: type }, type);
                })));
        }

        function renderCategories() {
            var filter = categoryFilter.value.trim().toLowerCase();
            var filtered = categories.filter(function(c) { return c.name.includes(filter); });
            var visible = filtered.slice(0, displayedCategories);
            var nodes = visible.map(function(c) {
                var button = actionButton(c.name + ' (' + c.count + ')' +
                    (c.inverse ? ' [inverse]' : ''), selected === c.name);
                button.style.display = 'block';
                button.style.width = '100%';
                button.style.textAlign = 'left';
                button.style.margin = '.2rem 0';
                button.onclick = function() {
                    selected = c.name;
                    currentPage = 0;
                    entryFilter.value = '';
                    entryType.value = 'all';
                    renderCategories();
                    browse();
                };
                return button;
            });

            if (!filtered.length)
                nodes.push(E('div', {}, _('No categories found.')));
            if (filtered.length > visible.length) {
                var more = actionButton(_('Show more categories'), false);
                more.style.width = '100%';
                more.onclick = function() { displayedCategories += 160; renderCategories(); };
                nodes.push(more);
                nodes.push(E('p', { 'class': 'cbi-section-descr' },
                    _('%s of %s categories shown').format(visible.length, filtered.length)));
            }
            categoryList.replaceChildren.apply(categoryList, nodes);
        }

        function showSearch(result, kind, mode) {
            var nodes = [
                E('p', {}, [
                    E('strong', {}, String(result.total)),
                    _(' matching rules in '),
                    E('strong', {}, String(result.category_total)),
                    _(' categories')
                ])
            ];
            if (result.truncated)
                nodes.push(E('p', { 'class': 'cbi-section-descr' },
                    _('Only the first 80 matching categories are displayed.')));
            if (kind === 'geosite' && mode === 'match')
                nodes.push(E('p', { 'class': 'cbi-section-descr' },
                    _('GeoSite regexp rules were not evaluated; these results may be incomplete.')));

            (result.categories || []).forEach(function(group) {
                var open = actionButton(_('Browse category'), false);
                open.onclick = function() {
                    selected = group.name;
                    currentPage = 0;
                    entryFilter.value = '';
                    entryType.value = 'all';
                    renderCategories();
                    browse();
                };

                var preview = Array.isArray(group.matches) ? group.matches : [];
                var rows = preview.map(function(item) {
                    var parts = [
                        E('code', {}, item.type || ''),
                        '  ',
                        E('code', {}, item.value || '')
                    ];
                    if (item.attributes && item.attributes.length)
                        parts.push('  ', E('small', {}, item.attributes.join(', ')));

                    return E('div', { 'style': 'margin:.2rem 0;overflow-wrap:anywhere;' }, parts);
                });

                if (group.total > preview.length)
                    rows.push(E('p', { 'class': 'cbi-section-descr' },
                        _('Showing first %s of %s matching rules').format(preview.length, group.total)));

                nodes.push(E('div', { 'class': 'cbi-section' }, [
                    E('div', { 'class': 'cbi-section-node' }, [
                        E('div', { 'style': 'display:flex;align-items:center;justify-content:space-between;flex-wrap:wrap;gap:.5rem;' }, [
                            E('strong', {}, group.name + ' (' + group.total + ')' +
                                (group.inverse ? ' [' + _('inverse') + ']' : '')),
                            open
                        ]),
                        E('div', {}, rows)
                    ])
                ]));
            });

            if (!result.categories || !result.categories.length)
                nodes.push(E('p', {}, _('No matching rules found.')));

            output.replaceChildren.apply(output, nodes);
        }

        function browse() {
            if (!ready || !selected) return Promise.resolve();
            invalidate();
            var turn = revision;
            cancelButton.style.display = '';
            title.textContent = (dataset.value === 'geosite' ? 'GeoSite' : 'GeoIP') + ' / ' + selected;
            browseControls.hidden = false;
            output.replaceChildren(E('p', {}, _('Loading category rules...')));
            setStatus('notice', _('Reading rules in browser...'));
            return send('browse', {
                category: selected, page: currentPage, filter: entryFilter.value.trim(),
                type: entryType.value
            }).then(function(data) {
                if (turn !== revision) return;
                var result = data.result;
                output.replaceChildren(resultTable(result.entries));
                pageTotal = result.total;
                previous.disabled = currentPage === 0;
                next.disabled = (currentPage + 1) * PAGE_SIZE >= pageTotal;
                pageInfo.textContent = result.total
                    ? _('%s\u2013%s of %s').format(currentPage * PAGE_SIZE + 1,
                        currentPage * PAGE_SIZE + result.entries.length, result.total)
                    : _('0 results');
                setStatus('ok', '');
            }).catch(function(error) {
                if (turn === revision) errorMessage(error);
            }).finally(function() {
                if (turn === revision) cancelButton.style.display = 'none';
            });
        }

        function search() {
            if (!ready || !query.value.trim()) return;
            invalidate();
            var turn = revision, kind = dataset.value, mode = searchMode.value;
            cancelButton.style.display = '';
            searchButton.disabled = true;
            selected = null;
            renderCategories();
            browseControls.hidden = true;
            title.textContent = _('Global search');
            output.replaceChildren(E('p', {}, _('Searching in browser...')));
            setStatus('notice', _('Searching in browser... 0%'));

            return send('search', {
                query: query.value.trim(), mode: mode,
                regex: regex.checked, sensitive: sensitive.checked
            }, null, function(progress) {
                if (turn !== revision) return;
                var value = progress.total ? Math.round(progress.scanned * 100 / progress.total) : 100;
                setStatus('notice', _('Searching in browser... %s%%').format(value));
            }).then(function(data) {
                if (turn !== revision) return;
                showSearch(data.result, kind, mode);
                setStatus('ok', '');
            }).catch(function(error) {
                if (turn === revision) {
                    output.replaceChildren(E('p', { 'class': 'error' }, _('Search failed.')));
                    errorMessage(error);
                }
            }).finally(function() {
                if (turn === revision) {
                    cancelButton.style.display = 'none';
                    searchButton.disabled = false;
                }
            });
        }

        function loadDataset(force) {
            invalidate();
            var turn = revision, kind = dataset.value;
            ready = false;
            selected = null;
            categories = [];
            displayedCategories = 160;
            currentPage = 0;
            pageTotal = 0;
            fileInfo.textContent = '';
            categoryList.replaceChildren();
            title.textContent = _('Rules');
            browseControls.hidden = true;
            previous.disabled = next.disabled = true;
            pageInfo.textContent = '';
            output.replaceChildren(E('p', {}, _('Choose a category after the file loads.')));
            query.placeholder = kind === 'geoip' ? '1.1.1.1' : 'www.youtube.com';
            typeOptions(kind);
            cancelButton.style.display = '';
            setStatus('notice', _('Checking GeoData file...'));

            return callFileInfo(kind).then(check).then(async function(info) {
                if (turn !== revision) return;

                var cached = force ? null : await cacheOperation(kind, null);
                if (turn !== revision) return;
                var blob, reused = cacheMatches(cached, info);
                if (reused) {
                    blob = cached.blob;
                } else {
                    setStatus('notice', _('Downloading GeoData file to browser...'));
                    blob = await fs.read_direct(info.read_path, 'blob');
                    if (!(blob instanceof Blob) || blob.size !== info.size)
                        throw new Error(_('GeoData file changed during transfer. Reload the file.'));
                    // Browser-only storage; the router never builds a search index.
                    cacheOperation(kind, {
                        version: 1, kind: kind, source: info.source,
                        size: info.size, mtime: info.mtime, ctime: info.ctime,
                        blob: blob
                    });
                }
                if (turn !== revision) return;
                setStatus('notice', _('Indexing GeoData file in browser...'));
                var buffer = await blob.arrayBuffer();
                if (turn !== revision) return;
                var reply = await send('load', { kind: kind, buffer: buffer }, [ buffer ]);
                if (turn !== revision) return;

                ready = true;
                categories = reply.result.categories;
                fileInfo.textContent = info.source + ' \u00b7 ' +
                    nftflowUi.formatBytes(info.size) + ' \u00b7 ' +
                    categories.length + ' ' + _('categories') +
                    (reused ? ' \u00b7 ' + _('Browser cache') : '');
                renderCategories();
                setStatus('ok', '');
            }).catch(function(error) {
                if (turn === revision) errorMessage(error);
            }).finally(function() {
                if (turn === revision) cancelButton.style.display = 'none';
            });
        }

        try {
            worker = new Worker(L.resource('nftflow/geodata-worker.js'));
            worker.onmessage = function(event) {
                var message = event.data || {};
                var request = pending[message.id];
                if (!request) return;
                if (message.type === 'progress') {
                    if (request.progress) request.progress(message);
                } else {
                    delete pending[message.id];
                    if (message.type === 'error')
                        request.reject(new Error(message.error || _('GeoData worker error.')));
                    else
                        request.resolve(message);
                }
            };
            worker.onerror = function(event) {
                var failure = new Error(event.message || _('GeoData Worker failed.'));
                Object.keys(pending).forEach(function(key) {
                    pending[key].reject(failure);
                    delete pending[key];
                });
                errorMessage(failure);
            };
        } catch (error) {
            errorMessage(error);
        }

        cancelButton.style.display = 'none';
        browseControls.hidden = true;
        previous.disabled = next.disabled = true;
        updateModes();

        dataset.onchange = function() { loadDataset(false); };
        searchMode.onchange = updateModes;
        categoryFilter.oninput = function() {
            displayedCategories = 160;
            renderCategories();
        };
        searchButton.onclick = search;
        cancelButton.onclick = function() {
            invalidate();
            output.replaceChildren(E('p', {}, _('Operation cancelled.')));
            setStatus('notice', _('Operation cancelled.'));
        };
        reloadButton.onclick = function() { loadDataset(true); };
        query.onkeydown = function(event) {
            if (event.key === 'Enter') search();
        };
        entryFilter.onkeydown = function(event) {
            if (event.key === 'Enter') { currentPage = 0; browse(); }
        };
        entryType.onchange = function() { currentPage = 0; browse(); };
        previous.onclick = function() {
            if (currentPage) { currentPage--; browse(); }
        };
        next.onclick = function() {
            if ((currentPage + 1) * PAGE_SIZE < pageTotal) { currentPage++; browse(); }
        };

        if (worker) loadDataset(false);
        return root;
    }
});
