import { fireEvent, render, screen } from '@testing-library/react'
import { describe, expect, it } from 'vitest'
import App from './App'

describe('React starter', () => {
  it('renders an accessible counter and updates it when clicked', () => {
    render(<App />)
    expect(screen.getByRole('heading', { level: 1 }).textContent).toBeTruthy()
    const counter = screen.getByRole('button', { name: /count is 0/i })
    fireEvent.click(counter)
    expect(screen.getByRole('button', { name: /count is 1/i })).toBeTruthy()
    fireEvent.click(counter)
    expect(screen.getByRole('button', { name: /count is 2/i })).toBeTruthy()
  })
})
