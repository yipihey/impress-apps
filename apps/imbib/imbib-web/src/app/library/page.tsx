'use client'

import { useSession, signIn, signOut } from "next-auth/react"
import useSWR from "swr"
import { useRouter } from "next/navigation"

interface Publication {
  id: string
  title: string
  author: string
  journal?: string
  year?: string
  // Add other fields as per your Prisma schema
}

const fetcher = (url: string) => fetch(url).then((res) => res.json())

export default function LibraryPage() {
  const { data: session, status } = useSession()
  const router = useRouter()

  const { data: publications, error } = useSWR<Publication[]>(
    session ? "/api/publications" : null,
    fetcher
  )

  if (status === "loading") {
    return <p>Loading session...</p>
  }

  if (!session) {
    return (
      <div className="min-h-screen flex flex-col items-center justify-center bg-gray-100 p-4">
        <h1 className="text-3xl font-bold mb-4">Welcome to imbib-web</h1>
        <p className="text-lg text-gray-700 mb-6">Please sign in to access your library.</p>
        <button
          onClick={() => signIn("github")}
          className="px-6 py-3 bg-blue-600 text-white font-semibold rounded-md shadow-md hover:bg-blue-700 transition duration-300"
        >
          Sign in with GitHub
        </button>
      </div>
    )
  }

  if (error) return <p>Failed to load publications.</p>
  if (!publications) return <p>Loading publications...</p>

  return (
    <div className="min-h-screen bg-gray-50 p-6">
      <header className="flex justify-between items-center mb-8">
        <h1 className="text-4xl font-extrabold text-gray-900">My Library</h1>
        <div className="flex items-center space-x-4">
          {session.user?.image && (
            <img
              src={session.user.image}
              alt="User Avatar"
              className="w-10 h-10 rounded-full border-2 border-blue-500"
            />
          )}
          <span className="text-lg font-medium text-gray-800">
            {session.user?.name || session.user?.email}
          </span>
          <button
            onClick={() => signOut()}
            className="px-4 py-2 bg-red-600 text-white font-semibold rounded-md shadow-sm hover:bg-red-700 transition duration-300"
          >
            Sign out
          </button>
        </div>
      </header>

      <main>
        {publications.length === 0 ? (
          <p className="text-xl text-gray-600 text-center mt-20">Your library is empty. Add some publications!</p>
        ) : (
          <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6">
            {publications.map((pub) => (
              <div
                key={pub.id}
                className="bg-white rounded-lg shadow-lg p-6 hover:shadow-xl transition-shadow duration-300 border border-gray-200"
              >
                <h2 className="text-xl font-bold text-gray-900 mb-2">{pub.title}</h2>
                <p className="text-gray-700 text-sm"><strong>Author:</strong> {pub.author}</p>
                {pub.journal && <p className="text-gray-600 text-sm"><strong>Journal:</strong> {pub.journal}</p>}
                {pub.year && <p className="text-gray-600 text-sm"><strong>Year:</strong> {pub.year}</p>}
              </div>
            ))}
          </div>
        )}
      </main>
    </div>
  )
}
