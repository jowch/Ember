import { Decoration, ViewPlugin, syntaxTree } from "../../imports/CodemirrorPlutoSetup.js"

const assigned = Decoration.mark({ class: "cm-ember-assigned" })

const assigned_decorations = (view) => {
    const ranges = []
    syntaxTree(view.state).iterate({
        from: view.viewport.from,
        to: view.viewport.to,
        enter: (node) => {
            if (node.name !== "AssignExpr" && node.name !== "EqAssign") return
            const op = node.node.getChild("AssignOp")
            if (op == null) return
            const rightward = view.state.sliceDoc(op.from, op.to).startsWith("-")
            const target = rightward ? node.node.lastChild : node.node.firstChild
            if (target?.name === "Identifier") ranges.push(assigned.range(target.from, target.to))
        },
    })
    return Decoration.set(ranges, true)
}

/**
 * Marks the name an assignment binds (`x` in `x <- 1`, `x = 1` and
 * `1 -> x`) with `cm-ember-assigned`, which takes the function colour as on
 * the Cells board. The R grammar tags these names only as variables.
 */
export const highlight_assigned = ViewPlugin.fromClass(
    class {
        constructor(view) {
            this.decorations = assigned_decorations(view)
        }
        update(update) {
            if (update.docChanged || update.viewportChanged || syntaxTree(update.startState) != syntaxTree(update.state)) {
                this.decorations = assigned_decorations(update.view)
            }
        }
    },
    { decorations: (v) => v.decorations }
)
