import { html } from "../imports/Preact.js"

// EXAMPLE:

/*
cl({a: true, b: false, c: true})
 ==
"a c "
*/

export const cl = (classTable) => {
    if (!classTable) {
        return null
    }
    return Object.entries(classTable).reduce((allClasses, [nextClass, enable]) => (enable ? nextClass + " " + allClasses : allClasses), "")
}

export const InlineIonicon = (icon_name, { inlineMargin = false } = {}) => {
    return html`<span class=${cl({ "ionicon-icon": true, "ionicon-icon-margin": inlineMargin })} data-icon=${icon_name} data-inline="true"></span>`
}
