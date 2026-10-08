import { useState } from 'react'

export default function App() {
  const [count, setCount] = useState(0)

  return (
    <main>
      <p className="eyebrow">Your next idea starts here</p>
      <h1>React app</h1>
      <p>A frontend you can make your own.</p>
      <button onClick={() => setCount(value => value + 1)}>Count is {count}</button>
      <p className="hint">Edit <code>src/App.tsx</code> to get started.</p>
    </main>
  )
}
