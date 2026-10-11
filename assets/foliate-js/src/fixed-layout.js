const parseViewport = str => str
    ?.split(/[,;\s]/) // NOTE: technically, only the comma is valid
    ?.filter(x => x)
    ?.map(x => x.split('=').map(x => x.trim()))

const getViewport = (doc, viewport) => {
    // use `viewBox` for SVG
    if (doc.documentElement.localName === 'svg') {
        const [, , width, height] = doc.documentElement
            .getAttribute('viewBox')?.split(/\s/) ?? []
        return { width, height }
    }

    // get `viewport` `meta` element
    const meta = parseViewport(doc.querySelector('meta[name="viewport"]')
        ?.getAttribute('content'))
    if (meta) return Object.fromEntries(meta)

    // fallback to book's viewport
    if (typeof viewport === 'string') return parseViewport(viewport)
    if (viewport) return viewport

    // if no viewport (possibly with image directly in spine), get image size
    const img = doc.querySelector('img')
    if (img) return { width: img.naturalWidth, height: img.naturalHeight }

    // just show *something*, i guess...
    console.warn(new Error('Missing viewport properties'))
    return { width: 1000, height: 2000 }
}

export class FixedLayout extends HTMLElement {
    #root = this.attachShadow({ mode: 'closed' })
    #observer = new ResizeObserver(() => this.#render())
    #spreads
    #index = -1
    defaultViewport
    spread
    #portrait = false
    #left
    #right
    #center
    #side
    #scroller
    #content
    #zoom = 1
    #ready = false
    #navigation = 0
    #wheelTimer
    #wheelDelta = 0
    #viewportRequest
    #frameLoads = new Set()
    #panMode = false
    #drag
    #suppressClick = false
    #panListeners = new Map()
    #destroyed = false
    constructor() {
        super()

        const sheet = new CSSStyleSheet()
        this.#root.adoptedStyleSheets = [sheet]
        sheet.replaceSync(`:host {
            width: 100%;
            height: 100%;
            display: flex;
            justify-content: center;
            align-items: center;
        }`)

        this.#observer.observe(this)
    }
    get zoom() { return this.#zoom }
    get ready() { return this.#ready }
    get panMode() { return this.#panMode }
    #reportZoom() {
        this.dispatchEvent(new CustomEvent('zoom-change', { detail: {
            isPdf: !!this.book?.isPdf, ready: this.#ready,
            percent: Math.round(this.#zoom * 100),
            panMode: this.#panMode,
        } }))
    }
    #reportViewport = () => {
        if (this.#destroyed) return
        cancelAnimationFrame(this.#viewportRequest)
        this.#viewportRequest = requestAnimationFrame(() => {
            if (!this.#destroyed) this.dispatchEvent(new Event('viewport-change'))
        })
    }
    #pageRect() {
        const frames = [this.#left, this.#right, this.#center]
            .filter(frame => frame && frame.element.style.display !== 'none')
        const rects = frames.map(frame => frame.element.getBoundingClientRect())
        if (!rects.length) return null
        return { left: Math.min(...rects.map(r => r.left)),
            top: Math.min(...rects.map(r => r.top)) }
    }
    setZoom(value, point) {
        if (!this.book?.isPdf || !this.#ready || !Number.isFinite(value)) return
        const zoom = Math.max(.5, Math.min(3, value))
        if (zoom === this.#zoom) return
        this.#endDrag()
        const wasFit = this.#zoom <= 1
        const old = this.#pageRect()
        const rect = this.#scroller.getBoundingClientRect()
        const anchor = point ?? { x: rect.left + this.#scroller.clientWidth / 2,
            y: rect.top + this.#scroller.clientHeight / 2 }
        const ratio = zoom / this.#zoom
        this.#zoom = zoom
        if (zoom <= 1) this.#panMode = false
        else if (wasFit) this.#panMode = true
        this.#updatePanStyle()
        this.#render()
        const next = this.#pageRect()
        if (old && next) {
            this.#scroller.scrollLeft += next.left + (anchor.x - old.left) * ratio - anchor.x
            this.#scroller.scrollTop += next.top + (anchor.y - old.top) * ratio - anchor.y
        }
        if (zoom <= 1) this.#resetScroll()
        this.#reportZoom()
    }
    setPanMode(enabled) {
        if (!this.book?.isPdf || !this.#ready || this.#zoom <= 1) return
        this.#endDrag()
        this.#panMode = !!enabled
        this.#updatePanStyle()
        this.#reportZoom()
    }
    #updatePanStyle() {
        const cursor = this.#panMode ? (this.#drag?.moved ? 'grabbing' : 'grab') : ''
        if (this.#scroller) {
            this.#scroller.style.cursor = cursor
            this.#scroller.style.userSelect = this.#panMode ? 'none' : ''
        }
        for (const doc of this.#panListeners.keys()) {
            if (doc === this.ownerDocument) continue
            const root = doc.documentElement
            if (this.#panMode) {
                root.setAttribute('data-pdf-pan', cursor)
                doc.getSelection()?.removeAllRanges()
            } else root.removeAttribute('data-pdf-pan')
        }
    }
    #pointerPoint(event, doc) {
        const frame = doc.defaultView?.frameElement
        const rect = frame?.getBoundingClientRect()
        return rect ? { x: rect.left + event.clientX * doc.scale,
            y: rect.top + event.clientY * doc.scale }
            : { x: event.clientX, y: event.clientY }
    }
    #endDrag = () => {
        const drag = this.#drag
        if (!drag) return
        this.#drag = null
        if (drag.moved) this.#suppressClick = true
        if (drag.target.hasPointerCapture(drag.id)) drag.target.releasePointerCapture(drag.id)
        this.#updatePanStyle()
    }
    #bindPan(doc, target = doc) {
        const down = event => {
            this.#suppressClick = false
            if (!this.#ready || !this.#panMode || event.pointerType !== 'mouse'
                || event.button !== 0 || event.target.closest?.('input, textarea, select, [contenteditable]')) return
            if (event.target === this.#scroller) {
                const rect = this.#scroller.getBoundingClientRect()
                if (event.clientX >= rect.left + this.#scroller.clientWidth
                    || event.clientY >= rect.top + this.#scroller.clientHeight) return
            }
            this.#endDrag()
            this.#suppressClick = false
            const point = this.#pointerPoint(event, doc)
            this.#drag = { id: event.pointerId, target: event.target,
                x: point.x, y: point.y, left: this.#scroller.scrollLeft,
                top: this.#scroller.scrollTop, moved: false }
            event.preventDefault()
            event.stopImmediatePropagation()
        }
        const move = event => {
            const drag = this.#drag
            if (!drag || drag.id !== event.pointerId) return
            if (!(event.buttons & 1)) { this.#endDrag(); return }
            const point = this.#pointerPoint(event, doc)
            const dx = point.x - drag.x, dy = point.y - drag.y
            if (!drag.moved && Math.hypot(dx, dy) <= 4) return
            if (!drag.moved) {
                drag.moved = true
                drag.target.setPointerCapture(drag.id)
                this.#updatePanStyle()
            }
            this.#scroller.scrollLeft = drag.left - dx
            this.#scroller.scrollTop = drag.top - dy
            event.preventDefault()
            event.stopImmediatePropagation()
        }
        const up = event => {
            if (this.#drag?.id !== event.pointerId) return
            this.#endDrag()
            event.stopImmediatePropagation()
        }
        const click = event => {
            if (!this.#suppressClick || event.button !== 0) return
            this.#suppressClick = false
            event.preventDefault()
            event.stopImmediatePropagation()
        }
        const handlers = { pointerdown: down, pointermove: move, pointerup: up,
            pointercancel: up, lostpointercapture: up, click }
        for (const [name, handler] of Object.entries(handlers)) target.addEventListener(name, handler, true)
        const win = doc.defaultView
        win.addEventListener('blur', this.#endDrag)
        this.#panListeners.set(doc, () => {
            for (const [name, handler] of Object.entries(handlers)) target.removeEventListener(name, handler, true)
            win.removeEventListener('blur', this.#endDrag)
        })
        if (doc !== this.ownerDocument) {
            const style = doc.createElement('style')
            style.textContent = `:root[data-pdf-pan], :root[data-pdf-pan] * {
                cursor: grab !important; user-select: none !important;
                -webkit-user-select: none !important;
            }
            :root[data-pdf-pan="grabbing"], :root[data-pdf-pan="grabbing"] * { cursor: grabbing !important; }`
            doc.head.append(style)
        }
        this.#updatePanStyle()
    }
    #resetScroll() {
        if (!this.#scroller) return
        this.#scroller.scrollTop = 0
        this.#scroller.scrollLeft = 0
    }
    #handleWheel = (event, doc) => {
        if (!this.book?.isPdf) return
        if (event.ctrlKey) {
            event.preventDefault()
            event.stopPropagation()
            if (!event.deltaY) return
            const rect = doc?.defaultView?.frameElement?.getBoundingClientRect()
            const point = rect ? { x: rect.left + event.clientX * doc.scale,
                y: rect.top + event.clientY * doc.scale }
                : { x: event.clientX, y: event.clientY }
            this.setZoom(this.#zoom + (event.deltaY < 0 ? .25 : -.25), point)
            return
        }
        if (this.#zoom > 1) {
            // Wheel events inside an iframe cannot scroll its parent container.
            event.preventDefault()
            event.stopPropagation()
            const unit = event.deltaMode === 1 ? 16
                : event.deltaMode === 2 ? this.#scroller.clientHeight : 1
            this.#scroller.scrollLeft += event.deltaX * unit
            this.#scroller.scrollTop += event.deltaY * unit
            return
        }
        if (this.getAttribute('flow') === 'scrolled'
            || this.getAttribute('keyboard-shortcut-turn-page') === 'true') return
        event.preventDefault()
        this.#wheelDelta += event.deltaY
        clearTimeout(this.#wheelTimer)
        this.#wheelTimer = setTimeout(() => {
            if (Math.abs(this.#wheelDelta) >= 50) {
                const action = this.#wheelDelta > 0 ? this.next() : this.prev()
                action?.catch(console.warn)
            }
            this.#wheelDelta = 0
        }, 80)
    }
    #releaseFrames() {
        this.#endDrag()
        for (const [doc, dispose] of this.#panListeners) {
            if (doc === this.ownerDocument) continue
            dispose()
            this.#panListeners.delete(doc)
        }
        for (const frame of [this.#left, this.#right, this.#center]) {
            if (frame && !frame.blank)
                this.book.sections[frame.index]?.releaseRender?.(frame.iframe.contentDocument)
        }
    }
    async #createFrame(position, { index, src }) {
        const element = document.createElement('div')
        const iframe = document.createElement('iframe')
        element.append(iframe)
        Object.assign(iframe.style, {
            border: '0',
            display: 'none',
            overflow: 'hidden',
        })
        // `allow-scripts` is needed for events because of WebKit bug
        // https://bugs.webkit.org/show_bug.cgi?id=218086
        iframe.setAttribute('sandbox', 'allow-same-origin allow-scripts')
        iframe.setAttribute('scrolling', 'no')
        iframe.setAttribute('part', 'filter')
        ;(this.#content ?? this.#root).append(element)
        if (!src) return { blank: true, element, iframe }
        return new Promise(resolve => {
            const cancel = () => {
                iframe.removeEventListener('load', onload)
                element.remove()
                resolve(null)
            }
            const onload = () => {
                iframe.removeEventListener('load', onload)
                this.#frameLoads.delete(cancel)
                const doc = iframe.contentDocument
                doc.position = position
                if (this.book.isPdf) {
                    doc.addEventListener('wheel', event => this.#handleWheel(event, doc), { passive: false })
                    this.#bindPan(doc)
                }
                this.dispatchEvent(new CustomEvent('load', { detail: { doc, index } }))
                const { width, height } = getViewport(doc, this.defaultViewport)
                resolve({
                    element, iframe, index,
                    width: parseFloat(width),
                    height: parseFloat(height),
                })
            }
            this.#frameLoads.add(cancel)
            iframe.addEventListener('load', onload)
            iframe.src = src
        })
    }
    #render(side = this.#side) {
        if (this.#destroyed) return
        if (!side) return
        const left = this.#left ?? {}
        const right = this.#center ?? this.#right
        if (!right || (!this.#center && !this.#left)) return
        const target = side === 'left' ? left : right
        const { width, height } = this.getBoundingClientRect()
        const portrait = this.spread !== 'both' && this.spread !== 'portrait'
            && height > width
        this.#portrait = portrait
        const blankWidth = left.width ?? right.width
        const blankHeight = left.height ?? right.height

        const fitScale = portrait || this.#center
            ? Math.min(
                width / (target.width ?? blankWidth),
                height / (target.height ?? blankHeight))
            : Math.min(
                width / ((left.width ?? blankWidth) + (right.width ?? blankWidth)),
                height / Math.max(
                    left.height ?? blankHeight,
                    right.height ?? blankHeight))

        const scale = fitScale * this.#zoom
        const transform = frame => {
            const { element, iframe, width, height, blank } = frame
            iframe.contentDocument.scale = scale
            Object.assign(iframe.style, {
                width: `${width}px`,
                height: `${height}px`,
                transform: `scale(${scale})`,
                transformOrigin: 'top left',
                display: blank ? 'none' : 'block',
            })
            Object.assign(element.style, {
                width: `${(width ?? blankWidth) * scale}px`,
                height: `${(height ?? blankHeight) * scale}px`,
                overflow: 'hidden',
                display: 'block',
            })
            if (portrait && frame !== target) {
                element.style.display = 'none'
            }
            if (!blank && element.style.display !== 'none')
                this.book.sections[frame.index]?.render?.(iframe.contentDocument, scale)
        }
        if (this.#center) {
            transform(this.#center)
        } else {
            transform(left)
            transform(right)
        }
        if (this.book.isPdf) this.#reportViewport()
    }
    async #showSpread({ left, right, center, side }, navigation) {
        this.#releaseFrames()
        ;(this.#content ?? this.#root).replaceChildren()
        this.#left = null
        this.#right = null
        this.#center = null
        if (center) {
            const frame = await this.#createFrame('center', center)
            if (navigation !== this.#navigation) return
            this.#center = frame
            this.#side = 'center'
            this.#render()
        } else {
            const frameL = await this.#createFrame('left', left)
            if (navigation !== this.#navigation) return
            this.#left = frameL
            const frameR = await this.#createFrame('right', right)
            if (navigation !== this.#navigation) return
            this.#right = frameR
            this.#side = this.#left.blank ? 'right'
                : this.#right.blank ? 'left' : side
            this.#render()
        }
        this.#resetScroll()
    }
    #goLeft() {
        if (this.#center || this.#left?.blank) return
        if (this.#portrait && this.#left?.element?.style?.display === 'none') {
            this.#endDrag()
            this.#right.element.style.display = 'none'
            this.#left.element.style.display = 'block'
            this.#side = 'left'
            this.#render()
            this.#resetScroll()
            return true
        }
    }
    #goRight() {
        if (this.#center || this.#right?.blank) return
        if (this.#portrait && this.#right?.element?.style?.display === 'none') {
            this.#endDrag()
            this.#left.element.style.display = 'none'
            this.#right.element.style.display = 'block'
            this.#side = 'right'
            this.#render()
            this.#resetScroll()
            return true
        }
    }
    open(book) {
        this.book = book
        this.#zoom = 1
        this.#panMode = false
        this.#ready = false
        if (book.isPdf) {
            this.style.display = 'block'
            this.#scroller = document.createElement('div')
            this.#scroller.setAttribute('part', 'pdf-scroll')
            Object.assign(this.#scroller.style, {
                width: '100%', height: '100%', overflow: 'auto',
                overscrollBehavior: 'contain', overflowAnchor: 'none',
            })
            this.#content = document.createElement('div')
            Object.assign(this.#content.style, {
                display: 'flex', width: 'max-content', minWidth: '100%', minHeight: '100%',
                justifyContent: 'center', alignItems: 'center',
            })
            this.#scroller.append(this.#content)
            this.#root.append(this.#scroller)
            this.#scroller.addEventListener('wheel', this.#handleWheel, { passive: false })
            this.#scroller.addEventListener('scroll', this.#reportViewport)
            this.#bindPan(this.ownerDocument, this.#scroller)
        }
        const { rendition } = book
        this.spread = rendition?.spread
        this.defaultViewport = rendition?.viewport

        const rtl = book.dir === 'rtl'
        const ltr = !rtl
        this.rtl = rtl

        if (rendition?.spread === 'none')
            this.#spreads = book.sections.map(section => ({ center: section }))
        else this.#spreads = book.sections.reduce((arr, section) => {
            const last = arr[arr.length - 1]
            const { linear, pageSpread } = section
            if (linear === 'no') return arr
            const newSpread = () => {
                const spread = {}
                arr.push(spread)
                return spread
            }
            if (pageSpread === 'center') {
                const spread = last.left || last.right ? newSpread() : last
                spread.center = section
            }
            else if (pageSpread === 'left') {
                const spread = last.center || last.left || ltr ? newSpread() : last
                spread.left = section
            }
            else if (pageSpread === 'right') {
                const spread = last.center || last.right || rtl ? newSpread() : last
                spread.right = section
            }
            else if (ltr) {
                if (last.center || last.right) newSpread().left = section
                else if (last.left) last.right = section
                else last.left = section
            }
            else {
                if (last.center || last.left) newSpread().right = section
                else if (last.right) last.left = section
                else last .right = section
            }
            return arr
        }, [{}])
    }
    get index() {
        const spread = this.#spreads[this.#index]
        const section = spread?.center ?? (this.#side === 'left'
            ? spread.left ?? spread.right : spread.right ?? spread.left)
        return this.book.sections.indexOf(section)
    }
    #reportLocation(reason) {
        this.dispatchEvent(new CustomEvent('relocate', { detail:
            { reason, range: null, index: this.index, fraction: 0, size: 1 } }))
    }
    getSpreadOf(section) {
        const spreads = this.#spreads
        for (let index = 0; index < spreads.length; index++) {
            const { left, right, center } = spreads[index]
            if (left === section) return { index, side: 'left' }
            if (right === section) return { index, side: 'right' }
            if (center === section) return { index, side: 'center' }
        }
    }
    async goToSpread(index, side, reason) {
        if (index < 0 || index > this.#spreads.length - 1) return
        this.#endDrag()
        if (index === this.#index) {
            if (!this.#ready) return
            this.#side = side ?? this.#side
            this.#render(side)
            this.#resetScroll()
            this.#reportLocation(reason)
            return
        }
        const navigation = ++this.#navigation
        for (const cancel of this.#frameLoads) cancel()
        this.#frameLoads.clear()
        this.#ready = false
        this.#reportZoom()
        this.#index = index
        const spread = this.#spreads[index]
        if (spread.center) {
            const index = this.book.sections.indexOf(spread.center)
            const src = await spread.center?.load?.()
            if (navigation !== this.#navigation) return
            await this.#showSpread({ center: { index, src } }, navigation)
        } else {
            const indexL = this.book.sections.indexOf(spread.left)
            const indexR = this.book.sections.indexOf(spread.right)
            const srcL = await spread.left?.load?.()
            const srcR = await spread.right?.load?.()
            if (navigation !== this.#navigation) return
            const left = { index: indexL, src: srcL }
            const right = { index: indexR, src: srcR }
            await this.#showSpread({ left, right, side }, navigation)
        }
        if (navigation !== this.#navigation) return
        this.#ready = true
        this.#reportZoom()
        this.#reportLocation(reason)
    }
    async select(target) {
        await this.goTo(target)
        // TODO
    }
    async goTo(target) {
        const { book } = this
        const resolved = await target
        const section = book.sections[resolved.index]
        if (!section) return
        const { index, side } = this.getSpreadOf(section)
        await this.goToSpread(index, side)
    }
    async next() {
        const s = this.#ready && (this.rtl ? this.#goLeft() : this.#goRight())
        if (s) this.#reportLocation('page')
        else return this.goToSpread(this.#index + 1, this.rtl ? 'right' : 'left', 'page')
    }
    async prev() {
        const s = this.#ready && (this.rtl ? this.#goRight() : this.#goLeft())
        if (s) this.#reportLocation('page')
        else return this.goToSpread(this.#index - 1, this.rtl ? 'left' : 'right', 'page')
    }
    getContents() {
        return [this.#left, this.#right, this.#center]
            .filter(frame => frame && !frame.blank)
            .map(frame => ({ doc: frame.iframe.contentDocument, index: frame.index }))
    }
    destroy() {
        if (this.#destroyed) return
        this.#destroyed = true
        this.#endDrag()
        this.#ready = false
        ++this.#navigation
        for (const cancel of this.#frameLoads) cancel()
        this.#frameLoads.clear()
        clearTimeout(this.#wheelTimer)
        cancelAnimationFrame(this.#viewportRequest)
        this.#releaseFrames()
        for (const dispose of this.#panListeners.values()) dispose()
        this.#panListeners.clear()
        this.book?.destroy?.()
        this.#observer.unobserve(this)
    }
}

customElements.define('foliate-fxl', FixedLayout)
