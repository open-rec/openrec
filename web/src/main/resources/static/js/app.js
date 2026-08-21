/**
 * open-rec web demo.
 *
 * Four tabs render item cards; every interaction is pushed back to rec-server through the backend,
 * which calls the java sdk. Reload "猜你喜欢" after clicking a few cards and the result set moves,
 * because click history is what userTrigger reads to build its triggers.
 */
(function () {
  'use strict';

  var TAB_LABEL = {
    guess: '猜你喜欢',
    related: '相关推荐',
    hot: '热门推荐',
    new: '新品推荐'
  };

  /** behaviours the DAG actually consumes; the rest are stored but inert */
  var AFFECTING = ['click', 'expose'];

  var state = {
    tab: 'guess',
    userId: 'user_0',
    scene: 'scene_0',
    pageSize: 12,
    /** trigger item for the related tab */
    relatedItemId: null,
    /** ids from the previous load of this tab, used to mark what changed */
    previousIds: {},
    /** itemId -> timestamp when the card entered the viewport, for dwell time */
    visibleSince: {},
    /** cluster mode reports each card at most once per rendered result set */
    exposedInRender: {},
    exposureMode: 'server',
    observer: null
  };

  var el = {
    userId: document.getElementById('userId'),
    scene: document.getElementById('scene'),
    reload: document.getElementById('reload'),
    reset: document.getElementById('reset'),
    tabs: document.getElementById('tabs'),
    source: document.getElementById('source'),
    note: document.getElementById('note'),
    grid: document.getElementById('grid'),
    empty: document.getElementById('empty'),
    toast: document.getElementById('toast')
  };

  // ---------------------------------------------------------------- helpers

  function toast(message, isError) {
    el.toast.textContent = message;
    el.toast.className = 'toast show' + (isError ? ' err' : '');
    clearTimeout(toast.timer);
    toast.timer = setTimeout(function () {
      el.toast.className = 'toast';
    }, 2600);
  }

  function getJson(url) {
    return fetch(url).then(function (res) {
      if (!res.ok) throw new Error('HTTP ' + res.status);
      return res.json();
    });
  }

  function postJson(url, body) {
    return fetch(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body || {})
    }).then(function (res) {
      if (!res.ok) throw new Error('HTTP ' + res.status);
      return res.json();
    });
  }

  // ---------------------------------------------------------------- counters

  function renderCounters(counters) {
    if (!counters) return;
    Object.keys(counters).forEach(function (type) {
      var node = document.querySelector('.counter[data-type="' + type + '"]');
      if (!node) return;

      var bold = node.querySelector('b');
      var previous = bold.textContent;
      var next = String(counters[type]);
      bold.textContent = next;

      if (AFFECTING.indexOf(type) >= 0) node.classList.add('live');
      if (previous !== '-' && previous !== next) {
        node.classList.remove('bump');
        // force a reflow so the animation restarts on repeated increments
        void node.offsetWidth;
        node.classList.add('bump');
      }
    });
  }

  function refreshCounters() {
    getJson('/api/state?userId=' + encodeURIComponent(state.userId) +
            '&scene=' + encodeURIComponent(state.scene))
      .then(function (data) { renderCounters(data.counters); })
      .catch(function () { /* counters are informational, never block the page */ });
  }

  // ---------------------------------------------------------------- feedback

  function report(itemId, type, value) {
    return postJson('/api/feedback', {
      userId: state.userId,
      scene: state.scene,
      itemId: itemId,
      type: type,
      value: value
    }).then(function (data) {
      if (!data.ok) {
        toast('上报失败: ' + (data.error || type), true);
        return data;
      }
      renderCounters(data.counters);
      return data;
    }).catch(function (err) {
      toast('上报失败: ' + err.message, true);
    });
  }

  function reportExposureBatch(itemIds) {
    if (!itemIds.length || state.exposureMode !== 'viewport') return;
    postJson('/api/feedback/batch', {
      userId: state.userId,
      scene: state.scene,
      itemIds: itemIds,
      type: 'expose'
    }).then(function (data) {
      if (!data.ok) throw new Error(data.error || 'expose');
      renderCounters(data.counters);
    }).catch(function (err) {
      itemIds.forEach(function (itemId) { delete state.exposedInRender[itemId]; });
      toast('曝光上报失败: ' + err.message, true);
    });
  }

  function reportStay(itemId) {
    var since = state.visibleSince[itemId];
    if (!since) return;
    delete state.visibleSince[itemId];

    var seconds = Math.round((Date.now() - since) / 1000);
    if (seconds < 1) return;              // ignore a card that merely scrolled past
    report(itemId, 'stay', String(seconds));
  }

  // ---------------------------------------------------------------- viewport tracking

  /** Tracks dwell time in both modes and real browser-visible exposure in cluster mode. */
  function setupObserver() {
    if (state.observer) state.observer.disconnect();

    if (!('IntersectionObserver' in window)) {
      return null;
    }

    state.observer = new IntersectionObserver(function (entries) {
      var newlyExposed = [];
      entries.forEach(function (entry) {
        var itemId = entry.target.dataset.itemId;
        if (!itemId) return;

        if (entry.isIntersecting) {
          if (!state.visibleSince[itemId]) state.visibleSince[itemId] = Date.now();
          if (state.exposureMode === 'viewport' && !state.exposedInRender[itemId]) {
            state.exposedInRender[itemId] = true;
            newlyExposed.push(itemId);
          }
        } else {
          reportStay(itemId);
        }
      });
      reportExposureBatch(newlyExposed);
    }, { threshold: 0.5 });

    return state.observer;
  }

  /** cards still on screen when the tab changes would otherwise never report their dwell time */
  function flushStay() {
    Object.keys(state.visibleSince).forEach(reportStay);
  }

  // ---------------------------------------------------------------- rendering

  /** colour per recall channel, so a glance at the grid shows the mix */
  var CHANNEL_CLASS = {
    i2i: 'badge-i2i',
    embedding: 'badge-embedding',
    hot: 'badge-hot',
    new: 'badge-fresh'
  };

  /**
   * score is what the list is ordered by; meta carries the breakdown behind it, e.g.
   * "recall=i2i:0.1700,hot:1.0000; rank=0.7700". An item recalled by several channels lists all of
   * them, because whether channels agree is exactly what you need when tuning the strategy. A dash
   * marks a stage that did not run, as opposed to one that scored 0.
   */
  function scoreBreakdown(item) {
    var html = '<div class="card-score">score ' + Number(item.score).toFixed(4) + '</div>';
    if (item.meta) {
      html += '<div class="card-meta" title="点击可选中复制">' + item.meta + '</div>';
    }
    return html;
  }

  /** how many channels recalled this item, for the multi-hit badge */
  function channelCount(item) {
    return item.recallScores ? Object.keys(item.recallScores).length : (item.recallFrom ? 1 : 0);
  }

  function card(item, isNew) {
    var node = document.createElement('div');
    node.className = 'card' + (item.resolved ? '' : ' unresolved');
    node.dataset.itemId = item.id;

    var badges = '<div class="card-badges">';
    if (item.recallFrom) {
      var hits = channelCount(item);
      badges += '<span class="badge ' + (CHANNEL_CLASS[item.recallFrom] || '') + '">' +
                item.recallFrom + (hits > 1 ? ' +' + (hits - 1) : '') + '</span>';
    }
    if (isNew) badges += '<span class="badge badge-new">NEW</span>';
    if (state.tab === 'related' && item.id === state.relatedItemId) {
      badges += '<span class="badge badge-trigger">trigger</span>';
    }
    badges += '</div>';

    var fields = '';
    if (item.resolved) {
      fields =
        '<div class="card-fields">' +
        '<div><span>类目</span> ' + (item.category || '-') + '</div>' +
        '<div><span>标签</span> ' + (item.tags || '-') + '</div>' +
        '<div><span>场景</span> ' + (item.scene || '-') + '</div>' +
        '</div>';
    } else {
      fields = '<div class="card-fields"><div class="dim">召回表里有这个 id，但 Redis 中没有对应的 item</div></div>';
    }

    node.innerHTML =
      badges +
      '<div class="card-title">' + (item.title || item.id) + '</div>' +
      '<div class="card-id">' + item.id + '</div>' +
      fields +
      scoreBreakdown(item) +
      '<div class="card-actions">' +
      '<button data-act="collect">收藏</button>' +
      '<button data-act="buy">购买</button>' +
      '<button data-act="related">相关</button>' +
      '</div>';

    // clicking the card body is the click behaviour; buttons handle themselves
    node.addEventListener('click', function (event) {
      if (event.target.closest('.card-actions')) return;
      node.classList.add('clicked');
      report(item.id, 'click').then(function () {
        toast('已记录 click：' + item.id + '，重新加载「猜你喜欢」即可看到变化');
      });
    });

    node.querySelectorAll('.card-actions button').forEach(function (button) {
      button.addEventListener('click', function (event) {
        event.stopPropagation();
        var act = button.dataset.act;

        if (act === 'related') {
          state.relatedItemId = item.id;
          switchTab('related');
          return;
        }

        report(item.id, act).then(function () {
          button.classList.add('done');
          toast('已记录 ' + act + '（仅存储，不影响推荐）');
        });
      });
    });

    return node;
  }

  function render(data) {
    el.grid.innerHTML = '';
    el.source.textContent = data.source ? '数据来源: ' + data.source : '';
    el.note.textContent = data.note || '';

    var items = data.items || [];
    if (data.error) {
      el.empty.textContent = data.error;
      el.empty.classList.remove('hidden');
      return;
    }

    if (!items.length) {
      el.empty.innerHTML = emptyMessage(data);
      el.empty.classList.remove('hidden');
      return;
    }
    el.empty.classList.add('hidden');

    var previous = state.previousIds[state.tab];
    var observer = setupObserver();

    items.forEach(function (item) {
      // only mark movement once there is a baseline to compare against
      var isNew = !!previous && previous.indexOf(item.id) < 0;
      var node = card(item, isNew);
      el.grid.appendChild(node);
      if (observer) observer.observe(node);
    });

    state.previousIds[state.tab] = items.map(function (item) { return item.id; });
  }

  function emptyMessage(data) {
    if (state.tab === 'related' && !state.relatedItemId) {
      return '先在其他 tab 点击某张卡片的「相关」按钮，再回到这里。';
    }
    if (state.tab === 'guess') {
      return '没有候选了。<br>每次推荐都会写入曝光记录，24 小时内曝光过的物品会被过滤掉 —— ' +
             '点右上角「重置曝光」即可恢复。';
    }
    return '这个场景下没有数据，确认 example/init 已经加载过 ' + state.scene + ' 的数据。';
  }

  // ---------------------------------------------------------------- loading

  function load() {
    flushStay();
    state.visibleSince = {};
    state.exposedInRender = {};

    var url = '/api/tab/' + state.tab +
              '?scene=' + encodeURIComponent(state.scene) +
              '&userId=' + encodeURIComponent(state.userId) +
              '&size=' + state.pageSize;
    if (state.tab === 'related' && state.relatedItemId) {
      url += '&itemId=' + encodeURIComponent(state.relatedItemId);
    }

    el.grid.innerHTML = '';
    el.empty.textContent = '加载中…';
    el.empty.classList.remove('hidden');

    getJson(url)
      .then(render)
      .catch(function (err) {
        el.empty.textContent = '加载失败: ' + err.message + '，确认 rec-server 与 Redis 是否在运行';
        el.empty.classList.remove('hidden');
      });

    refreshCounters();
  }

  function switchTab(tab) {
    state.tab = tab;
    Array.prototype.forEach.call(el.tabs.children, function (button) {
      button.classList.toggle('active', button.dataset.tab === tab);
    });
    load();
  }

  // ---------------------------------------------------------------- wiring

  el.tabs.addEventListener('click', function (event) {
    var button = event.target.closest('.tab');
    if (button) switchTab(button.dataset.tab);
  });

  el.reload.addEventListener('click', load);

  el.userId.addEventListener('change', function () {
    state.userId = el.userId.value.trim() || 'user_0';
    el.userId.value = state.userId;
    state.previousIds = {};      // a different user has an unrelated baseline
    load();
  });

  el.scene.addEventListener('change', function () {
    state.scene = el.scene.value;
    state.previousIds = {};
    state.relatedItemId = null;
    load();
  });

  el.reset.addEventListener('click', function () {
    postJson('/api/reset', { userId: state.userId, scene: state.scene })
      .then(function (data) {
        renderCounters(data.counters);
        toast('已清除曝光记录，候选池恢复');
        state.previousIds = {};
        load();
      })
      .catch(function (err) { toast('重置失败: ' + err.message, true); });
  });

  // dwell time for whatever is still on screen when the page goes away
  window.addEventListener('beforeunload', flushStay);
  document.addEventListener('visibilitychange', function () {
    if (document.hidden) flushStay();
  });

  // ---------------------------------------------------------------- boot

  getJson('/api/config')
    .then(function (cfg) {
      state.userId = cfg.userId || state.userId;
      state.scene = cfg.scene || state.scene;
      state.pageSize = cfg.pageSize || state.pageSize;
      state.exposureMode = cfg.exposureMode || state.exposureMode;
      if (cfg.affectingBehaviours && cfg.affectingBehaviours.length) {
        AFFECTING = cfg.affectingBehaviours;
      }

      el.userId.value = state.userId;
      (cfg.scenes || [state.scene]).forEach(function (scene) {
        var option = document.createElement('option');
        option.value = scene;
        option.textContent = scene;
        option.selected = scene === state.scene;
        el.scene.appendChild(option);
      });
    })
    .catch(function () {
      // backend defaults unavailable: fall back to the values already in the markup
      var option = document.createElement('option');
      option.value = state.scene;
      option.textContent = state.scene;
      el.scene.appendChild(option);
    })
    .then(function () { switchTab('guess'); });
})();
