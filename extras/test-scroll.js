#!/usr/bin/env node
// Exercises whole-row scrolling and the wheel's touchpad banking without a view:
//   node extras/test-scroll.js
"use strict"

const assert = require("node:assert/strict")
const Scroll = require("../Scroll.js")

let failed = 0
function check(name, fn) {
    try {
        fn()
        console.log("ok   " + name)
    } catch (err) {
        failed++
        console.log("FAIL " + name + "\n     " + String(err.message).replace(/\n/g, "\n     "))
    }
}

const target = (contentY, contentHeight, viewportHeight, pitch, rows) =>
    Scroll.rowScrollTarget(contentY, contentHeight, viewportHeight, pitch, rows)

// ---- which row a step lands on ----

check("rowScrollTarget: one row down from a row boundary", () => {
    // 10 rows of 30 in a 100px viewport: maxY = 200
    assert.equal(target(0, 300, 100, 30, 1), 30)
    assert.equal(target(60, 300, 100, 30, 2), 120)
})

check("rowScrollTarget: steps back up", () => {
    assert.equal(target(120, 300, 100, 30, -1), 90)
})

check("rowScrollTarget: never above the top", () => {
    assert.equal(target(0, 300, 100, 30, -1), 0)
    assert.equal(target(10, 300, 100, 30, -1), 0)
})

check("rowScrollTarget: never past the last full viewport", () => {
    // maxY = 200; two rows from 150 would be 240
    assert.equal(target(150, 300, 100, 30, 2), 200)
    assert.equal(target(200, 300, 100, 30, 5), 200)
})

check("rowScrollTarget: a list shorter than its viewport does not move", () => {
    assert.equal(target(0, 80, 100, 30, 1), 0)
})

check("rowScrollTarget: an off-grid position snaps to a row first", () => {
    // 44 is nearer 30 than 60, so two rows down is 90 rather than 104.
    assert.equal(target(44, 500, 100, 30, 2), 90)
    // 46 is nearer 60.
    assert.equal(target(46, 500, 100, 30, 2), 120)
})

check("rowScrollTarget: no rows, or no pitch, leaves it alone", () => {
    assert.equal(target(60, 300, 100, 30, 0), 60)
    assert.equal(target(60, 300, 100, 0, 1), 60)
    assert.equal(target(60, 300, 100, -5, 1), 60)
})

// ---- one wheel event ----

check("wheelStep: one mouse notch is one row, up or down", () => {
    assert.deepEqual(Scroll.wheelStep(0, -120, 30, 0), { rows: 1, banked: 0 })
    assert.deepEqual(Scroll.wheelStep(0, 120, 30, 0), { rows: -1, banked: 0 })
})

check("wheelStep: an angle delta's size does not scale the step", () => {
    // Some wheels report 240 per notch; the step is the notch, not the count.
    assert.deepEqual(Scroll.wheelStep(0, -240, 30, 0), { rows: 1, banked: 0 })
})

check("wheelStep: a touchpad's pixels bank until they fill a row", () => {
    let step = Scroll.wheelStep(10, 0, 30, 0)
    assert.deepEqual(step, { rows: 0, banked: 10 })
    step = Scroll.wheelStep(10, 0, 30, step.banked)
    assert.deepEqual(step, { rows: 0, banked: 20 })
    step = Scroll.wheelStep(10, 0, 30, step.banked)
    assert.deepEqual(step, { rows: -1, banked: 0 })
})

check("wheelStep: the remainder carries into the next event", () => {
    let step = Scroll.wheelStep(40, 0, 30, 0)
    assert.deepEqual(step, { rows: -1, banked: 10 })
    step = Scroll.wheelStep(4, 0, 30, step.banked)
    assert.deepEqual(step, { rows: 0, banked: 14 })
})

check("wheelStep: a fast flick moves several rows at once", () => {
    assert.deepEqual(Scroll.wheelStep(90, 0, 30, 0), { rows: -3, banked: 0 })
    assert.deepEqual(Scroll.wheelStep(95, 0, 30, 0), { rows: -3, banked: 5 })
})

check("wheelStep: up the list is negative pixels", () => {
    let step = Scroll.wheelStep(-10, 0, 30, 0)
    assert.deepEqual(step, { rows: 0, banked: -10 })
    step = Scroll.wheelStep(-20, 0, 30, step.banked)
    assert.deepEqual(step, { rows: 1, banked: 0 })
})

check("wheelStep: an event with no delta does nothing", () => {
    assert.deepEqual(Scroll.wheelStep(0, 0, 30, 7), { rows: 0, banked: 7 })
})

check("wheelStep: no pitch means no movement, and the bank is kept", () => {
    assert.deepEqual(Scroll.wheelStep(10, 0, 0, 5), { rows: 0, banked: 5 })
    assert.deepEqual(Scroll.wheelStep(0, -120, 0, 0), { rows: 0, banked: 0 })
})

check("wheelStep: undefined deltas are treated as zero", () => {
    assert.deepEqual(Scroll.wheelStep(undefined, undefined, 30, undefined),
        { rows: 0, banked: 0 })
})

if (failed > 0) {
    console.log("\n" + failed + " failed")
    process.exit(1)
}
console.log("\nall passed")
